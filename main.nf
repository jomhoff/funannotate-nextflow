nextflow.enable.dsl = 2

params.genome = null
params.reads = null
params.species = null
params.outdir = 'results'
params.busco_db = 'tetrapoda'
params.busco_seed_species = 'Taeniopygia_guttata'
params.organism = 'other'
params.stranded = 'RF'
params.max_intronlen = 6000
params.funannotate_db = null
params.genemark_path = null
params.iprscan_path = null
params.corrected_tbl = null

def shellQuote(value) {
    "'${value.toString().replace("'", "'\\''")}'"
}

process TRAIN {
    tag "${species}"
    label 'train'

    input:
    path genome
    path left_reads
    path right_reads
    val species
    val stranded
    val max_intronlen
    val funannotate_db
    val genemark_path

    output:
    path 'annotation', emit: annotation

    script:
    def left = left_reads.collect { shellQuote(it.name) }.join(' ')
    def right = right_reads.collect { shellQuote(it.name) }.join(' ')
    """
    export FUNANNOTATE_DB=${shellQuote(funannotate_db)}
    export GENEMARK_PATH=${shellQuote(genemark_path)}
    funannotate train \
        -i ${shellQuote(genome.name)} \
        -o annotation \
        --left ${left} \
        --right ${right} \
        --species ${shellQuote(species)} \
        --max_intronlen ${max_intronlen} \
        --stranded ${shellQuote(stranded)} \
        --cpus ${task.cpus}
    """
}

process PREDICT {
    tag "${species}"
    label 'predict'

    input:
    path annotation_dir
    path genome
    val species
    val busco_db
    val organism
    val seed_species
    val funannotate_db
    val genemark_path

    output:
    path 'annotation', emit: annotation

    script:
    """
    export FUNANNOTATE_DB=${shellQuote(funannotate_db)}
    export GENEMARK_PATH=${shellQuote(genemark_path)}
    funannotate predict \
        -i ${shellQuote(genome.name)} \
        -o annotation \
        --species ${shellQuote(species)} \
        --busco_db ${shellQuote(busco_db)} \
        --organism ${shellQuote(organism)} \
        --busco_seed_species ${shellQuote(seed_species)} \
        --repeats2evm \
        --cpus ${task.cpus}
    """
}

process UPDATE {
    label 'update'

    input:
    path annotation_dir
    val funannotate_db
    val genemark_path

    output:
    path 'annotation', emit: annotation

    script:
    """
    export FUNANNOTATE_DB=${shellQuote(funannotate_db)}
    export GENEMARK_PATH=${shellQuote(genemark_path)}
    funannotate update -i annotation --cpus ${task.cpus}
    """
}

process FIX {
    label 'fix'

    input:
    path annotation_dir
    path corrected_tbl
    val funannotate_db
    val genemark_path

    output:
    path 'annotation', emit: annotation

    script:
    """
    export FUNANNOTATE_DB=${shellQuote(funannotate_db)}
    export GENEMARK_PATH=${shellQuote(genemark_path)}
    gbk=\$(find annotation/update_results -maxdepth 1 -type f \\( -name '*.gbk' -o -name '*.gbff' \\) | head -n 1)
    test -n "\$gbk" || { echo 'No update_results GenBank file found' >&2; exit 1; }
    funannotate fix -i "\$gbk" -t ${shellQuote(corrected_tbl.name)}
    """
}

process IPRSCAN {
    label 'iprscan'

    input:
    path annotation_dir
    val iprscan_path

    output:
    path 'annotation', emit: annotation

    script:
    """
    funannotate iprscan \
        -i annotation \
        --cpus ${task.cpus} \
        -m local \
        --iprscan_path ${shellQuote(iprscan_path)}
    """
}

process ANNOTATE {
    label 'annotate'
    publishDir "${params.outdir}", mode: 'copy', overwrite: true

    input:
    path annotation_dir
    val busco_db
    val funannotate_db
    val genemark_path

    output:
    path 'annotation', emit: annotation

    script:
    """
    export FUNANNOTATE_DB=${shellQuote(funannotate_db)}
    export GENEMARK_PATH=${shellQuote(genemark_path)}
    funannotate annotate \
        -i annotation \
        --busco_db ${shellQuote(busco_db)} \
        --cpus ${task.cpus}
    """
}

workflow {
    def required = [
        genome: params.genome,
        reads: params.reads,
        species: params.species,
        funannotate_db: params.funannotate_db,
        genemark_path: params.genemark_path,
        iprscan_path: params.iprscan_path
    ]
    def missing = required.findAll { !it.value }.keySet()
    if (missing) {
        error "Missing required parameter(s): ${missing.join(', ')}"
    }

    def rows = file(params.reads, checkIfExists: true)
        .readLines()
        .findAll { it.trim() && !it.startsWith('#') }
    if (rows && rows[0].toLowerCase().startsWith('sample\t')) rows = rows.drop(1)
    def pairs = rows.collect { line ->
        def fields = line.split('\\t', -1)
        if (fields.size() < 3) error "Reads TSV rows require sample, left, and right columns: ${line}"
        tuple(fields[0], file(fields[1], checkIfExists: true), file(fields[2], checkIfExists: true))
    }
    if (!pairs) error 'The reads TSV contains no read pairs'

    genome_ch = Channel.value(file(params.genome, checkIfExists: true))
    left_ch = Channel.value(pairs.collect { it[1] })
    right_ch = Channel.value(pairs.collect { it[2] })

    TRAIN(genome_ch, left_ch, right_ch, params.species, params.stranded,
          params.max_intronlen, params.funannotate_db, params.genemark_path)
    PREDICT(TRAIN.out.annotation, genome_ch, params.species, params.busco_db,
            params.organism, params.busco_seed_species, params.funannotate_db,
            params.genemark_path)
    UPDATE(PREDICT.out.annotation, params.funannotate_db, params.genemark_path)

    annotation_for_iprscan = UPDATE.out.annotation
    if (params.corrected_tbl) {
        FIX(UPDATE.out.annotation, file(params.corrected_tbl, checkIfExists: true),
            params.funannotate_db, params.genemark_path)
        annotation_for_iprscan = FIX.out.annotation
    }

    IPRSCAN(annotation_for_iprscan, params.iprscan_path)
    ANNOTATE(IPRSCAN.out.annotation, params.busco_db, params.funannotate_db,
             params.genemark_path)
}
