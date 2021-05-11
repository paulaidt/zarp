"""General purpose RNA-Seq analysis pipeline developed by the Zavolan Lab"""
import os
import pandas as pd
import shutil
import yaml
from shlex import quote
from typing import Tuple

## Preparations
# Get sample table
samples_table = pd.read_csv(
    config['samples'],
    header=0,
    index_col=0,
    comment='#',
    engine='python',
    sep="\t",
)

# Parse YAML rule config file
if 'rule_config' in config and config['rule_config']:
    try:
        with open(config['rule_config']) as _file:
            rule_config = yaml.safe_load(_file)
        logger.info(f"Loaded rule_config from {config['rule_config']}.")
    except FileNotFoundError:
        logger.error(f"No rule config file found at {config['rule_config']}. Either provide file or remove rule_config parameter from config.yaml! ")
        raise
else:
    rule_config = {}
    logger.warning(f"No rule config specified: using default values for all tools.")

# Create dir for cluster logs, if applicable
if cluster_config:
    os.makedirs(
        os.path.join(
            os.getcwd(),
            os.path.dirname(cluster_config['__default__']['out']),
        ),
        exist_ok=True)


## Function definitions

def get_sample(column_id, search_id=None, search_value=None):
    """ Get relevant per sample information from samples table"""
    if search_id:
        if search_id == 'index':
            return str(samples_table[column_id][samples_table.index == search_value][0])
        else:
            return str(samples_table[column_id][samples_table[search_id] == search_value][0])
    else:
        return str(samples_table[column_id][0])


def parse_rule_config(rule_config: dict, current_rule: str, immutable: Tuple[str, ...] = ()):
    """Get rule specific parameters from rule_config file"""
    
    # If rule config file not present, emtpy string will be returned
    if not rule_config:
        logger.info(f"No rule config specified: using default values for all tools.")
        return ''
    # Same if current rule not specified in rule config
    if current_rule not in rule_config or not rule_config[current_rule]:
        logger.info(f"No additional parameters for rule {current_rule} specified: using default settings.")
        return ''

    # Subset only section for current rule
    rule_config = rule_config[current_rule]
    
    # Build list of parameters and values
    params_vals = []
    for param, val in rule_config.items():
        # Do not allow the user to change wiring-critical, fixed arguments, or arguments that are passed through samples table
        if param in immutable:
            raise ValueError(
                f"The following parameter in rule {current_rule} is critical for the pipeline to "
                f"function as expected and cannot be modified: {param}"
            )
        # Accept only strings; this prevents unintended results potentially
        # arising from users entering reserved YAML keywords or nested
        # structures (lists, dictionaries)
        if isinstance(val, str):
            params_vals.append(str(param))
            # Do not include a value for flags (signified by empty strings)
            if val:
                params_vals.append(val)
        else:
            raise ValueError(
                "Only string values allowed for tool parameters: Found type "
                f"'{type(val).__name__}' for value of parameter '{param}'"
            )
    # Return quoted string
    add_params = ' '.join(quote(item) for item in params_vals)
    logger.info(f"User specified additional parameters for rule {current_rule}:\n {add_params}")
    return add_params


# Global config
localrules: start, finish, rename_star_rpm_for_alfa, prepare_multiqc_config

# Include subworkflows
include: os.path.join("workflow", "rules", "paired_end.snakefile.smk")
include: os.path.join("workflow", "rules", "single_end.snakefile.smk")


rule finish:
    """
        Rule for collecting outputs
    """
    input:
        multiqc_report = os.path.join(
            config['output_dir'],
            "multiqc_summary"),
        bigWig = expand(
            os.path.join(
                config["output_dir"],
                "samples",
                "{sample}",
                "bigWig",
                "{unique_type}",
                "{sample}_{unique_type}_{strand}.bw"),
            sample=pd.unique(samples_table.index.values),
            strand=["plus", "minus"],
            unique_type=["Unique", "UniqueMultiple"]),
        salmon_merge_genes = expand(
            os.path.join(
                config["output_dir"],
                "summary_salmon",
                "quantmerge",
                "genes_{salmon_merge_on}.tsv"),
            salmon_merge_on=["tpm", "numreads"]),
        salmon_merge_transcripts = expand(
            os.path.join(
                config["output_dir"],
                "summary_salmon",
                "quantmerge",
                "transcripts_{salmon_merge_on}.tsv"),
            salmon_merge_on=["tpm", "numreads"]),
        kallisto_merge_transcripts = os.path.join(
            config["output_dir"],
            "summary_kallisto",
            "transcripts_tpm.tsv"),
        kallisto_merge_genes = os.path.join(
            config["output_dir"],
            "summary_kallisto",
            "genes_tpm.tsv")


current_rule = 'start'
rule start:
    '''
       Get samples
    '''
    input:
        reads = lambda wildcards:
            expand(
                pd.Series(
                    samples_table.loc[wildcards.sample, wildcards.mate]
                ).values)

    output:
        reads = os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "start",
            "{sample}.{mate}.fastq.gz")

    log:
        stderr = os.path.join(
            config["log_dir"],
            "samples",
            "{sample}",
            current_rule + "_{sample}.{mate}.stderr.log"),
        stdout = os.path.join(
            config["log_dir"],
            "samples",
            "{sample}",
            current_rule + "_{sample}.{mate}.stdout.log")

    singularity:
        "docker://ubuntu:focal-20210416"

    shell:
        "(cat {input.reads} > {output.reads}) \
        1> {log.stdout} 2> {log.stderr} "


current_rule = 'fastqc'
rule fastqc:
    '''
        A quality control tool for high throughput sequence data
    '''
    input:
        reads = os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "start",
            "{sample}.{mate}.fastq.gz")

    output:
        outdir = directory(
            os.path.join(
                config["output_dir"],
                "samples",
                "{sample}",
                "fastqc",
                "{mate}"))
    
    params:
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '--outdir',
                )
            )

    threads: 2

    singularity:
        "docker://quay.io/biocontainers/fastqc:0.11.9--hdfd78af_1"

    log:
        stderr = os.path.join(
            config["log_dir"],
            "samples",
            "{sample}",
            current_rule + "_{mate}.stderr.log"),
        stdout = os.path.join(
            config["log_dir"],
            "samples",
            "{sample}",
            current_rule + "_{mate}.stdout.log")

    shell:
        "(mkdir -p {output.outdir}; \
        fastqc --outdir {output.outdir} \
        --threads {threads} \
        {params.additional_params} \
        {input.reads}) \
        1> {log.stdout} 2> {log.stderr}"


current_rule = 'create_index_star'
rule create_index_star:
    """
        Create index for STAR alignments
    """
    input:
        genome = lambda wildcards:
            os.path.abspath(get_sample(
                'genome',
                search_id='organism',
                search_value=wildcards.organism)),

        gtf = lambda wildcards:
            os.path.abspath(get_sample(
                'gtf',
                search_id='organism',
                search_value=wildcards.organism))

    output:
        chromosome_info = os.path.join(
            config['star_indexes'],
            "{organism}",
            "{index_size}",
            "STAR_index",
            "chrNameLength.txt"),
        chromosomes_names = os.path.join(
            config['star_indexes'],
            "{organism}",
            "{index_size}",
            "STAR_index",
            "chrName.txt")

    params:
        output_dir = os.path.join(
            config['star_indexes'],
            "{organism}",
            "{index_size}",
            "STAR_index"),
        outFileNamePrefix = os.path.join(
            config['star_indexes'],
            "{organism}",
            "{index_size}",
            "STAR_index/STAR_"),
        sjdbOverhang = "{index_size}",
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '--runMode',
                '--sjdbOverhang',
                '--genomeDir',
                '--genomeFastaFiles',
                '--outFileNamePrefix',
                '--sjdbGTFfile',
                )
            )

    singularity:
        "docker://quay.io/biocontainers/star:2.7.8a--h9ee0642_1"

    threads: 12

    log:
        stderr = os.path.join(
            config['log_dir'],
            current_rule + "_{organism}_{index_size}.stderr.log"),
        stdout = os.path.join(
            config['log_dir'],
            current_rule + "_{organism}_{index_size}.stdout.log")

    shell:
        "(mkdir -p {params.output_dir}; \
        chmod -R 777 {params.output_dir}; \
        STAR \
        --runMode genomeGenerate \
        --sjdbOverhang {params.sjdbOverhang} \
        --genomeDir {params.output_dir} \
        --genomeFastaFiles {input.genome} \
        --runThreadN {threads} \
        --outFileNamePrefix {params.outFileNamePrefix} \
        --sjdbGTFfile {input.gtf}) \
        {params.additional_params} \
        1> {log.stdout} 2> {log.stderr}"


current_rule = 'extract_transcriptome'
rule extract_transcriptome:
    """
        Create transcriptome from genome and gene annotations
    """
    input:
        genome = lambda wildcards:
            get_sample(
                'genome',
                search_id='organism',
                search_value=wildcards.organism),
        gtf = lambda wildcards:
            get_sample(
                'gtf',
                search_id='organism',
                search_value=wildcards.organism)
    output:
        transcriptome = temp(os.path.join(
            config['output_dir'],
            "transcriptome",
            "{organism}",
            "transcriptome.fa"))

    params:
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '-w',
                '-g',
                )
            )

    log:
        stderr = os.path.join(
            config['log_dir'],
            current_rule + "_{organism}.log"),
        stdout = os.path.join(
            config['log_dir'],
            current_rule + "_{organism}.log")

    singularity:
        "docker://quay.io/biocontainers/gffread:0.12.1--h2e03b76_1"

    shell:
        "(gffread \
        -w {output.transcriptome} \
        -g {input.genome} \
        {params.additional_params} \
        {input.gtf}) \
        1> {log.stdout} 2> {log.stderr}"


current_rule = 'concatenate_transcriptome_and_genome' 
rule concatenate_transcriptome_and_genome:
    """
        Concatenate genome and transcriptome
    """
    input:
        transcriptome = os.path.join(
            config['output_dir'],
            "transcriptome",
            "{organism}",
            "transcriptome.fa"),

        genome = lambda wildcards:
            get_sample(
                'genome',
                search_id='organism',
                search_value=wildcards.organism)

    output:
        genome_transcriptome = temp(os.path.join(
            config['output_dir'],
            "transcriptome",
            "{organism}",
            "genome_transcriptome.fa"))

    singularity:
        "docker://ubuntu:focal-20210416"

    log:
        stderr = os.path.join(
            config['log_dir'],
            current_rule + "_{organism}.stderr.log")

    shell:
        "(cat {input.transcriptome} {input.genome} \
        1> {output.genome_transcriptome}) \
        2> {log.stderr}"


current_rule = 'create_index_salmon'
rule create_index_salmon:
    """
        Create index for Salmon quantification
    """
    input:
        genome_transcriptome = os.path.join(
            config['output_dir'],
            "transcriptome",
            "{organism}",
            "genome_transcriptome.fa"),
        chr_names = lambda wildcards:
            os.path.join(
                config['star_indexes'],
                get_sample('organism'),
                get_sample("index_size"),
                "STAR_index",
                "chrName.txt")

    output:
        index = directory(
            os.path.join(
                config['salmon_indexes'],
                "{organism}",
                "{kmer}",
                "salmon.idx"))

    params:
        kmerLen = "{kmer}",
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '--transcripts',
                '--decoys',
                '--index',
                '--kmerLen',
                )
            )

    singularity:
        "docker://quay.io/biocontainers/salmon:1.4.0--h84f40af_1"

    log:
        stderr = os.path.join(
            config['log_dir'],
            current_rule + "_{organism}_{kmer}.stderr.log"),
        stdout = os.path.join(
            config['log_dir'],
            current_rule + "_{organism}_{kmer}.stdout.log")

    threads: 8

    shell:
        "(salmon index \
        --transcripts {input.genome_transcriptome} \
        --decoys {input.chr_names} \
        --index {output.index} \
        --kmerLen {params.kmerLen} \
        --threads {threads}) \
        {params.additional_params} \
        1> {log.stdout} 2> {log.stderr}"


current_rule = 'create_index_kallisto'
rule create_index_kallisto:
    """
        Create index for Kallisto quantification
    """
    input:
        transcriptome = os.path.join(
            config['output_dir'],
            "transcriptome",
            "{organism}",
            "transcriptome.fa")

    output:
        index = os.path.join(
            config['kallisto_indexes'],
            "{organism}",
            "kallisto.idx")

    params:
        output_dir = os.path.join(
            config['kallisto_indexes'],
            "{organism}"),
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '-i',
                )
            )

    singularity:
        "docker://quay.io/biocontainers/kallisto:0.46.2--h60f4f9f_2"

    log:
        stderr = os.path.join(
            config['log_dir'],
            current_rule + "_{organism}.stderr.log"),
        stdout = os.path.join(
            config['log_dir'],
            current_rule + "_{organism}.stdout.log")

    shell:
        "(mkdir -p {params.output_dir}; \
        chmod -R 777 {params.output_dir}; \
        kallisto index \
        {params.additional_params} \
        -i {output.index} \
        {input.transcriptome}) \
        1> {log.stdout}  2> {log.stderr}"


current_rule = 'extract_transcripts_as_bed12'
rule extract_transcripts_as_bed12:
    """
        Convert transcripts to BED12 format
    """
    input:
        gtf = lambda wildcards:
            get_sample('gtf')

    output:
        bed12 = temp(os.path.join(
            config['output_dir'],
            "full_transcripts_protein_coding.bed"))

    params:
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '--gtf',
                '--bed12',
                )
            )

    singularity:
        "docker://zavolab/zgtf:0.1"

    threads: 1

    log:
        stdout = os.path.join(
            config['log_dir'],
            current_rule + ".stdout.log"),
        stderr = os.path.join(
            config['log_dir'],
            current_rule + ".stderr.log")

    shell:
        "(gtf2bed12 \
        --gtf {input.gtf} \
        --bed12 {output.bed12}); \
        {params.additional_params} \
        1> {log.stdout} 2> {log.stderr}"


current_rule = 'index_genomic_alignment_samtools'
rule index_genomic_alignment_samtools:
    '''
        Index genome bamfile using samtools
    '''
    input:
        bam = os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "map_genome",
            "{sample}.{seqmode}.Aligned.sortedByCoord.out.bam"),
    output:
        bai = os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "map_genome",
            "{sample}.{seqmode}.Aligned.sortedByCoord.out.bam.bai")

    params:
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=()
            )

    singularity:
        "docker://quay.io/biocontainers/samtools:1.3.1--h1b8c3c0_8"

    threads: 1

    log:
        stderr = os.path.join(
            config["log_dir"],
            "samples",
            "{sample}",
            current_rule + ".{seqmode}.stderr.log"),
        stdout = os.path.join(
            config["log_dir"],
            "samples",
            "{sample}",
            current_rule + ".{seqmode}.stdout.log")

    shell:
        "(samtools index \
        {params.additional_params} \
        {input.bam} {output.bai};) \
        1> {log.stdout} 2> {log.stderr}"


current_rule = 'calculate_TIN_scores'
rule calculate_TIN_scores:
    """
        Calculate transcript integrity (TIN) score
    """
    input:
        bam = lambda wildcards:
            expand(
                os.path.join(
                    config['output_dir'],
                    "samples",
                    "{sample}",
                    "map_genome",
                    "{sample}.{seqmode}.Aligned.sortedByCoord.out.bam"),
                sample=wildcards.sample,
                seqmode=get_sample(
                    'seqmode',
                    search_id='index',
                    search_value=wildcards.sample)),
        bai = lambda wildcards:
            expand(
                os.path.join(
                    config['output_dir'],
                    "samples",
                    "{sample}",
                    "map_genome",
                    "{sample}.{seqmode}.Aligned.sortedByCoord.out.bam.bai"),
                sample=wildcards.sample,
                seqmode=get_sample(
                    'seqmode',
                    search_id='index',
                    search_value=wildcards.sample)),
        transcripts_bed12 = os.path.join(
            config['output_dir'],
            "full_transcripts_protein_coding.bed")

    output:
        TIN_score = temp(os.path.join(
            config['output_dir'],
            "samples",
            "{sample}",
            "TIN",
            "TIN_score.tsv"))

    params:
        sample = "{sample}",
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '-i',
                '-r',
                '--names',
                )
            )

    log:
        stderr = os.path.join(
            config['log_dir'],
            "samples",
            "{sample}",
            current_rule + ".log")

    threads: 8

    singularity:
        "docker://zavolab/tin_score_calculation:0.2.0-slim"

    shell:
        "(tin_score_calculation.py \
        -i {input.bam} \
        -r {input.transcripts_bed12} \
        --names {params.sample} \
        {params.additional_params} \
        > {output.TIN_score};) 2> {log.stderr}"


current_rule = 'salmon_quantmerge_genes'
rule salmon_quantmerge_genes:
    '''
        Merge gene quantifications into a single file
    '''
    input:
        salmon_in = expand(
            os.path.join(
                config["output_dir"],
                "samples",
                "{sample}",
                "{sample}.salmon.{seqmode}",
                "quant.sf"),
            zip,
            sample=pd.unique(samples_table.index.values),
            seqmode=[get_sample(
                'seqmode',
                search_id='index',
                search_value=i)
                for i in pd.unique(samples_table.index.values)])

    output:
        salmon_out = os.path.join(
            config["output_dir"],
            "summary_salmon",
            "quantmerge",
            "genes_{salmon_merge_on}.tsv")

    params:
        salmon_in = expand(
            os.path.join(
                config["output_dir"],
                "samples",
                "{sample}",
                "{sample}.salmon.{seqmode}"),
            zip,
            sample=[i for i in pd.unique(samples_table.index.values)],
            seqmode=[get_sample(
                'seqmode',
                search_id='index',
                search_value=i)
                for i in pd.unique(samples_table.index.values)]),
        sample_name_list = expand(
            "{sample}",
            sample=pd.unique(samples_table.index.values)),
        salmon_merge_on = "{salmon_merge_on}",
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '--quants',
                '--genes',
                '--transcripts',
                '--names',
                '--column',
                '--output',
                )
            )

    log:
        stderr = os.path.join(
            config["log_dir"],
            current_rule + "_{salmon_merge_on}.stderr.log"),
        stdout = os.path.join(
            config["log_dir"],
            current_rule + "_{salmon_merge_on}.stdout.log")

    threads: 1

    singularity:
        "docker://quay.io/biocontainers/salmon:1.4.0--h84f40af_1"

    shell:
        "(salmon quantmerge \
        --quants {params.salmon_in} \
        --genes \
        --names {params.sample_name_list} \
        --column {params.salmon_merge_on} \
        --output {output.salmon_out};) \
        {params.additional_params} \
        1> {log.stdout} 2> {log.stderr}"


current_rule = 'salmon_quantmerge_transcripts'
rule salmon_quantmerge_transcripts:
    '''
        Merge transcript quantifications into a single file
    '''
    input:
        salmon_in = expand(
            os.path.join(
                config["output_dir"],
                "samples",
                "{sample}",
                "{sample}.salmon.{seqmode}",
                "quant.sf"),
            zip,
            sample=[i for i in pd.unique(samples_table.index.values)],
            seqmode=[get_sample(
                'seqmode',
                search_id='index',
                search_value=i)
                for i in pd.unique(samples_table.index.values)])

    output:
        salmon_out = os.path.join(
            config["output_dir"],
            "summary_salmon",
            "quantmerge",
            "transcripts_{salmon_merge_on}.tsv")

    params:
        salmon_in = expand(
            os.path.join(
                config["output_dir"],
                "samples",
                "{sample}",
                "{sample}.salmon.{seqmode}"),
            zip,
            sample=[i for i in pd.unique(samples_table.index.values)],
            seqmode=[get_sample(
                'seqmode',
                search_id='index',
                search_value=i)
                for i in pd.unique(samples_table.index.values)]),
        sample_name_list = expand(
            "{sample}",
            sample=pd.unique(samples_table.index.values)),
        salmon_merge_on = "{salmon_merge_on}",
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '--quants',
                '--genes',
                '--transcripts',
                '--names',
                '--column',
                '--output',
                )
            )

    log:
        stderr = os.path.join(
            config["log_dir"],
            current_rule + "_{salmon_merge_on}.stderr.log"),
        stdout = os.path.join(
            config["log_dir"],
            current_rule + "_{salmon_merge_on}.stdout.log")

    threads: 1

    singularity:
        "docker://quay.io/biocontainers/salmon:1.4.0--h84f40af_1"

    shell:
        "(salmon quantmerge \
        --quants {params.salmon_in} \
        --names {params.sample_name_list} \
        --column {params.salmon_merge_on} \
        --output {output.salmon_out}) \
        {params.additional_params} \
        1> {log.stdout} 2> {log.stderr}"


current_rule= 'kallisto_merge_genes'
rule kallisto_merge_genes:
    '''
        Merge gene quantifications into single file
    '''
    input:
        pseudoalignment = expand(
            os.path.join(
                config["output_dir"],
                "samples",
                "{sample}",
                "quant_kallisto",
                "{sample}.{seqmode}.kallisto.pseudo.sam"),
            zip,
            sample=[i for i in pd.unique(samples_table.index.values)],
            seqmode=[get_sample(
                'seqmode',
                search_id='index',
                search_value=i)
                for i in pd.unique(samples_table.index.values)]),
        gtf = get_sample('gtf')

    output:
        gn_tpm = os.path.join(
            config["output_dir"],
            "summary_kallisto",
            "genes_tpm.tsv"),
        gn_counts = os.path.join(
            config["output_dir"],
            "summary_kallisto",
            "genes_counts.tsv")

    params:
        dir_out = os.path.join(
            config["output_dir"],
            "summary_kallisto"),
        tables = ','.join(expand(
            os.path.join(
                config["output_dir"],
                "samples",
                "{sample}",
                "quant_kallisto",
                "abundance.h5"),
            sample=[i for i in pd.unique(samples_table.index.values)])),
        sample_name_list = ','.join(expand(
            "{sample}",
            sample=pd.unique(samples_table.index.values))),
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '--input',
                '--names',
                '--txOut',
                '--anno',
                '--output',
                )
            )

    log:
        stderr = os.path.join(
            config["log_dir"],
            current_rule + ".stderr.log"),
        stdout = os.path.join(
            config["log_dir"],
            current_rule + ".stdout.log")

    threads: 1

    singularity:
        "docker://zavolab/merge_kallisto:0.6"

    shell:
        "(merge_kallisto.R \
        --input {params.tables} \
        --names {params.sample_name_list} \
        --txOut FALSE \
        --anno {input.gtf} \
        --output {params.dir_out} \
        {params.additional_params} ) \
        1> {log.stdout} 2> {log.stderr}"


current_rule = 'kallisto_merge_transcripts'
rule kallisto_merge_transcripts:
    '''
        Merge transcript quantifications into a single files
    '''
    input:
        pseudoalignment = expand(
            os.path.join(
                config["output_dir"],
                "samples",
                "{sample}",
                "quant_kallisto",
                "{sample}.{seqmode}.kallisto.pseudo.sam"),
            zip,
            sample=[i for i in pd.unique(samples_table.index.values)],
            seqmode=[get_sample(
                'seqmode',
                search_id='index',
                search_value=i)
                for i in pd.unique(samples_table.index.values)]),

    output:
        tx_tpm = os.path.join(
            config["output_dir"],
            "summary_kallisto",
            "transcripts_tpm.tsv"),
        tx_counts = os.path.join(
            config["output_dir"],
            "summary_kallisto",
            "transcripts_counts.tsv")

    params:
        dir_out = os.path.join(
            config["output_dir"],
            "summary_kallisto"),
        tables = ','.join(expand(
            os.path.join(
                config["output_dir"],
                "samples",
                "{sample}",
                "quant_kallisto",
                "abundance.h5"),
            sample=[i for i in pd.unique(samples_table.index.values)])),
        sample_name_list = ','.join(expand(
            "{sample}",
            sample=pd.unique(samples_table.index.values))),
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '--input',
                '--names',
                '--txOut',
                '--output',
                )
            )

    log:
        stderr = os.path.join(
            config["log_dir"],
            current_rule + ".stderr.log"),
        stdout = os.path.join(
            config["log_dir"],
            current_rule + ".stdout.log")

    threads: 1

    singularity:
        "docker://zavolab/merge_kallisto:0.6"

    shell:
        "(merge_kallisto.R \
        --input {params.tables} \
        --names {params.sample_name_list} \
        --output {params.dir_out} \
        {params.additional_params}) \
        1> {log.stdout} 2> {log.stderr}"


current_rule = 'pca_salmon'
rule pca_salmon:
    input:
        tpm = os.path.join(
            config["output_dir"],
            "summary_salmon",
            "quantmerge",
            "{molecule}_tpm.tsv"),

    output:
        out = directory(os.path.join(
            config["output_dir"],
            "zpca",
            "pca_salmon_{molecule}"))

    params:
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '--tpm',
                '--out',
                )
            )

    log:
        stderr = os.path.join(
            config["log_dir"],
            current_rule + "_{molecule}.stderr.log"),
        stdout = os.path.join(
            config["log_dir"],
            current_rule + "_{molecule}.stdout.log")

    threads: 1

    singularity:
        "docker://zavolab/zpca:0.8.3-1"

    shell:
        "(zpca-tpm  \
        --tpm {input.tpm} \
        --out {output.out} \
        {params.additional_params}) \
        1> {log.stdout} 2> {log.stderr}"


current_rule = 'pca_kallisto'
rule pca_kallisto:
    input:
        tpm = os.path.join(
            config["output_dir"],
            "summary_kallisto",
            "{molecule}_tpm.tsv")


    output:
        out = directory(os.path.join(
            config["output_dir"],
            "zpca",
            "pca_kallisto_{molecule}"))

    params:
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '--tpm',
                '--out',
                )
            )

    log:
        stderr = os.path.join(
            config["log_dir"],
            current_rule + "_{molecule}.stderr.log"),
        stdout = os.path.join(
            config["log_dir"],
            current_rule + "_{molecule}.stdout.log")

    threads: 1

    singularity:
        "docker://zavolab/zpca:0.8.3-1"

    shell:
        "(zpca-tpm  \
        --tpm {input.tpm} \
        --out {output.out} \
        {params.additional_params}) \
        1> {log.stdout} 2> {log.stderr}"


current_rule = 'star_rpm'
rule star_rpm:
    '''
        Create stranded bedgraph coverage with STARs RPM normalisation
    '''
    input:
        bam = lambda wildcards:
            expand(
                os.path.join(
                    config["output_dir"],
                    "samples",
                    "{sample}",
                    "map_genome",
                    "{sample}.{seqmode}.Aligned.sortedByCoord.out.bam"),
                sample=wildcards.sample,
                seqmode=get_sample(
                    'seqmode',
                    search_id='index',
                    search_value=wildcards.sample)),
        bai = lambda wildcards:
            expand(
                os.path.join(
                    config["output_dir"],
                    "samples",
                    "{sample}",
                    "map_genome",
                    "{sample}.{seqmode}.Aligned.sortedByCoord.out.bam.bai"),
                sample=wildcards.sample,
                seqmode=get_sample(
                    'seqmode',
                    search_id='index',
                    search_value=wildcards.sample))

    output:
        str1 = temp(os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "STAR_coverage",
            "{sample}_Signal.Unique.str1.out.bg")),
        str2 = temp(os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "STAR_coverage",
            "{sample}_Signal.UniqueMultiple.str1.out.bg")),
        str3 = temp(os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "STAR_coverage",
            "{sample}_Signal.Unique.str2.out.bg")),
        str4 = temp(os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "STAR_coverage",
            "{sample}_Signal.UniqueMultiple.str2.out.bg"))

    shadow: "full"

    params:
        out_dir = lambda wildcards, output:
            os.path.dirname(output.str1),
        prefix = lambda wildcards, output:
            os.path.join(
                os.path.dirname(output.str1),
                str(wildcards.sample) + "_"),
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '--runMode',
                '--inputBAMfile',
                '--outWigType',
                '--outFileNamePrefix',
                )
            )

    singularity:
        "docker://quay.io/biocontainers/star:2.7.8a--h9ee0642_1"

    log:
        stderr = os.path.join(
            config["log_dir"],
            "samples",
            "{sample}",
            current_rule + ".stderr.log"),
        stdout = os.path.join(
            config["log_dir"],
            "samples",
            "{sample}",
            current_rule + ".stdout.log")

    threads: 4

    shell:
        "(mkdir -p {params.out_dir}; \
        chmod -R 777 {params.out_dir}; \
        STAR \
        --runMode inputAlignmentsFromBAM \
        --runThreadN {threads} \
        --inputBAMfile {input.bam} \
        --outWigType bedGraph \
        --outFileNamePrefix {params.prefix}) \
        {params.additional_params} \
        1> {log.stdout} 2> {log.stderr}"


current_rule = 'rename_star_rpm_for_alfa'
rule rename_star_rpm_for_alfa:
    input:
        plus = lambda wildcards:
            expand(
                os.path.join(
                    config["output_dir"],
                    "samples",
                    "{sample}",
                    "STAR_coverage",
                    "{sample}_Signal.{unique}.{plus}.out.bg"),
                sample=wildcards.sample,
                unique=wildcards.unique,
                plus=get_sample(
                    'alfa_plus',
                    search_id='index',
                    search_value=wildcards.sample)),
        minus = lambda wildcards:
            expand(
                os.path.join(
                    config["output_dir"],
                    "samples",
                    "{sample}",
                    "STAR_coverage",
                    "{sample}_Signal.{unique}.{minus}.out.bg"),
                sample=wildcards.sample,
                unique=wildcards.unique,
                minus=get_sample(
                    'alfa_minus',
                    search_id='index',
                    search_value=wildcards.sample))

    output:
        plus = temp(os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "ALFA",
            "{unique}",
            "{sample}.{unique}.plus.bg")),
        minus = temp(os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "ALFA",
            "{unique}",
            "{sample}.{unique}.minus.bg"))

    log:
        stderr = os.path.join(
            config["log_dir"],
            "samples",
            "{sample}",
            current_rule + "_{unique}.stderr.log"),
        stdout = os.path.join(
            config["log_dir"],
            "samples",
            "{sample}",
            current_rule + "_{unique}.stdout.log")

    singularity:
        "docker://ubuntu:focal-20210416"

    shell:
        "(cp {input.plus} {output.plus}; \
         cp {input.minus} {output.minus};) \
         1>{log.stdout} 2>{log.stderr}"


current_rule = 'generate_alfa_index'
rule generate_alfa_index:
    ''' Generate ALFA index files from sorted GTF file '''
    input:
        gtf = lambda wildcards:
            os.path.abspath(get_sample(
                'gtf',
                search_id='organism',
                search_value=wildcards.organism)),
        chr_len = os.path.join(
            config["star_indexes"],
            "{organism}",
            "{index_size}",
            "STAR_index",
            "chrNameLength.txt"),

    output:
        index_stranded = os.path.join(
            config["alfa_indexes"],
            "{organism}",
            "{index_size}",
            "ALFA",
            "sorted_genes.stranded.ALFA_index"),
        index_unstranded = os.path.join(
            config["alfa_indexes"],
            "{organism}",
            "{index_size}",
            "ALFA",
            "sorted_genes.unstranded.ALFA_index")

    params:
        genome_index = "sorted_genes",
        out_dir = lambda wildcards, output:
            os.path.dirname(output.index_stranded),
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '-a',
                '-g',
                '--chr_len',
                '-o',
                )
            )

    threads: 4

    singularity:
        "docker://quay.io/biocontainers/alfa:1.1.1--pyh5e36f6f_0"

    log:
        os.path.join(
            config["log_dir"],
            current_rule + "_{organism}_{index_size}.log")

    shell:
        "(alfa -a {input.gtf} \
        -g {params.genome_index} \
        --chr_len {input.chr_len} \
        -p {threads} \
        -o {params.out_dir} \
        {params.additional_params}) \
        &> {log}"


current_rule = 'alfa_qc'
rule alfa_qc:
    '''
        Run ALFA from stranded bedgraph files
    '''
    input:
        plus = os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "ALFA",
            "{unique}",
            "{sample}.{unique}.plus.bg"),
        minus = os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "ALFA",
            "{unique}",
            "{sample}.{unique}.minus.bg"),
        gtf = lambda wildcards:
            os.path.join(
                config["alfa_indexes"],
                get_sample(
                    'organism',
                    search_id='index',
                    search_value=wildcards.sample),
                get_sample(
                    'index_size',
                    search_id='index',
                    search_value=wildcards.sample),
                "ALFA",
                "sorted_genes.stranded.ALFA_index")

    output:
        biotypes = temp(os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "ALFA",
            "{unique}",
            "ALFA_plots.Biotypes.pdf")),
        categories = temp(os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "ALFA",
            "{unique}",
            "ALFA_plots.Categories.pdf")),
        table = os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "ALFA",
            "{unique}",
            "{sample}.ALFA_feature_counts.tsv")

    params:
        out_dir = lambda wildcards, output:
            os.path.dirname(output.biotypes),
        genome_index = lambda wildcards, input:
            os.path.abspath(
                os.path.join(
                    os.path.dirname(input.gtf),
                    "sorted_genes")),
        plus = lambda wildcards, input:
            os.path.basename(input.plus),
        minus = lambda wildcards, input:
            os.path.basename(input.minus),
        name = "{sample}",
        alfa_orientation = lambda wildcards:
            get_sample(
                'alfa_directionality',
                search_id='index',
                search_value=wildcards.sample),
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '-g',
                '--bedgraph',
                '-s',
                )
            )

    singularity:
        "docker://quay.io/biocontainers/alfa:1.1.1--pyh5e36f6f_0"

    log:
        os.path.join(
            config["log_dir"],
            "samples",
            "{sample}",
            current_rule + ".{unique}.log")

    shell:
        "(cd {params.out_dir}; \
        alfa \
        -g {params.genome_index} \
        --bedgraph {params.plus} {params.minus} {params.name} \
        -s {params.alfa_orientation} \
        {params.additional_params}) \
        &> {log}"


current_rule = 'prepare_multiqc_config'
rule prepare_multiqc_config:
    '''
        Prepare config for the MultiQC
    '''
    input:
        script = os.path.join(
            workflow.basedir,
            "workflow",
            "scripts",
            "zarp_multiqc_config.py")

    output:
        multiqc_config = os.path.join(
            config["output_dir"],
            "multiqc_config.yaml")

    params:
        logo_path = config['report_logo'],
        multiqc_intro_text = config['report_description'],
        url = config['report_url'],
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '--config',
                '--intro-text',
                '--custom-logo',
                '--url',
                )
            )

    log:
        stderr = os.path.join(
            config["log_dir"],
            current_rule + ".stderr.log"),
        stdout = os.path.join(
            config["log_dir"],
            current_rule + ".stdout.log")

    shell:
        "(python {input.script} \
        --config {output.multiqc_config} \
        --intro-text '{params.multiqc_intro_text}' \
        --custom-logo {params.logo_path} \
        --url '{params.url}' \
        {params.additional_params}) \
        1> {log.stdout} 2> {log.stderr}"

current_rule = 'multiqc_report'
rule multiqc_report:
    '''
        Create report with MultiQC
    '''
    input:
        fastqc_se = expand(
            os.path.join(
                config['output_dir'],
                "samples",
                "{sample}",
                "fastqc",
                "{mate}"),
            sample=pd.unique(samples_table.index.values),
            mate="fq1"),

        fastqc_pe = expand(
            os.path.join(
                config['output_dir'],
                "samples",
                "{sample}",
                "fastqc",
                "{mate}"),
            sample=[i for i in pd.unique(
                samples_table[samples_table['seqmode'] == 'pe'].index.values)],
            mate="fq2"),

        pseudoalignment = expand(
            os.path.join(
                config['output_dir'],
                "samples",
                "{sample}",
                "quant_kallisto",
                "{sample}.{seqmode}.kallisto.pseudo.sam"),
            zip,
            sample=[i for i in pd.unique(samples_table.index.values)],
            seqmode=[get_sample('seqmode', search_id='index', search_value=i) 
                for i in pd.unique(samples_table.index.values)]),

        TIN_score = expand(
            os.path.join(
                config['output_dir'],
                "samples",
                "{sample}",
                "TIN",
                "TIN_score.tsv"),
            sample=pd.unique(samples_table.index.values)),

        tables = lambda wildcards:
            expand(
                os.path.join(
                    config["output_dir"],
                    "samples",
                    "{sample}",
                    "ALFA",
                    "{unique}",
                    "{sample}.ALFA_feature_counts.tsv"),
                sample=pd.unique(samples_table.index.values),
                unique=["Unique", "UniqueMultiple"]),

        zpca_salmon = expand(os.path.join(
            config["output_dir"],
            "zpca",
            "pca_salmon_{molecule}"),
            molecule=["genes", "transcripts"]),

        zpca_kallisto = expand(os.path.join(
            config["output_dir"],
            "zpca",
            "pca_kallisto_{molecule}"),
            molecule=["genes", "transcripts"]
        ),

        multiqc_config = os.path.join(
            config["output_dir"],
            "multiqc_config.yaml")

    output:
        multiqc_report = directory(
            os.path.join(
                config["output_dir"],
                "multiqc_summary"))

    params:
        results_dir = os.path.join(
            config["output_dir"]),
        log_dir = config["log_dir"],
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '--outdir',
                '--config',
                )
            )

    log:
        stderr = os.path.join(
            config["log_dir"],
            current_rule + ".stderr.log"),
        stdout = os.path.join(
            config["log_dir"],
            current_rule + ".stdout.log")

    singularity:
        "docker://zavolab/multiqc-plugins:1.2.1"

    shell:
        "(multiqc \
        --outdir {output.multiqc_report} \
        --config {input.multiqc_config} \
        {params.additional_params} \
        {params.results_dir} \
        {params.log_dir};) \
        1> {log.stdout} 2> {log.stderr}"

current_rule = 'sort_bed_4_big'
rule sort_bed_4_big:
    '''
        sort bedGraphs in order to work with bedGraphtobigWig
    '''
    input:
        bg = os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "ALFA",
            "{unique}",
            "{sample}.{unique}.{strand}.bg")

    output:
        sorted_bg = temp(os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "bigWig",
            "{unique}",
            "{sample}_{unique}_{strand}.sorted.bg"))

    params:
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=(
                '-i',
                )
            )

    singularity:
        "docker://quay.io/biocontainers/bedtools:2.27.1--h9a82719_5"

    log:
        stderr = os.path.join(
            config["log_dir"],
            "samples",
            "{sample}",
            current_rule + "_{unique}_{strand}.stderr.log")

    shell:
        "(sortBed \
        -i {input.bg} \
        {params.additional_params} \
        > {output.sorted_bg};) 2> {log.stderr}"


current_rule = 'prepare_bigWig'
rule prepare_bigWig:
    '''
        bedGraphtobigWig, for viewing in genome browsers
    '''
    input:
        sorted_bg = os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "bigWig",
            "{unique}",
            "{sample}_{unique}_{strand}.sorted.bg"),
        chr_sizes = lambda wildcards:
            os.path.join(
                config['star_indexes'],
                get_sample(
                    'organism',
                    search_id='index',
                    search_value=wildcards.sample),
                get_sample(
                    'index_size',
                    search_id='index',
                    search_value=wildcards.sample),
                "STAR_index",
                "chrNameLength.txt")

    output:
        bigWig = os.path.join(
            config["output_dir"],
            "samples",
            "{sample}",
            "bigWig",
            "{unique}",
            "{sample}_{unique}_{strand}.bw")

    params:
        additional_params = parse_rule_config(
            rule_config,
            current_rule=current_rule,
            immutable=()
            )

    singularity:
        "docker://quay.io/biocontainers/ucsc-bedgraphtobigwig:377--h0b8a92a_2"

    log:
        stderr = os.path.join(
            config["log_dir"],
            "samples",
            "{sample}",
            current_rule + "_{unique}_{strand}.stderr.log"),

        stdout = os.path.join(
            config["log_dir"],
            "samples",
            "{sample}",
            current_rule + "_{unique}_{strand}.stdout.log")

    shell:
        "(bedGraphToBigWig \
        {params.additional_params} \
        {input.sorted_bg} \
        {input.chr_sizes} \
        {output.bigWig};) \
        1> {log.stdout} 2> {log.stderr}"
