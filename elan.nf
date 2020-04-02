#!/usr/bin/env nextflow

Channel
    .fromPath(params.manifest)
    .splitCsv(header:['coguk_id', 'run_name', 'username', 'pipeuuid', 'dir', 'clabel', 'cuuid', 'fasta', 'alabel', 'auuid', 'bam'], sep:'\t')
    .filter { row -> row.fasta.size() > 0 }
    .filter { row -> row.bam.size() > 0 }
    .map { row-> tuple(row.username, row.dir, row.run_name, row.coguk_id, file([row.dir, row.fasta].join('/')), file([row.dir, row.bam].join('/'))) }
    .set { manifest_ch }

process samtools_quickcheck {
    tag { bam }
    conda "environments/samtools.yaml"
    label 'bear'

    errorStrategy 'ignore'

    input:
    tuple username, dir, run_name, coguk_id, file(fasta), file(bam) from manifest_ch

    output:
    tuple username, dir, run_name, coguk_id, file(fasta), file(bam) into valid_manifest_ch

    """
    samtools quickcheck $bam
    """
}

process samtools_filter_and_sort {
    tag { bam }
    conda "environments/samtools.yaml"
    label 'bear'

    input:
    tuple username, dir, run_name, coguk_id, file(fasta), file(bam) from valid_manifest_ch

    output:
    publishDir path : "${params.publish}/alignment", pattern: "${coguk_id}.${run_name}.climb.bam", mode: "copy", overwrite: true
    tuple username, dir, run_name, coguk_id, file(fasta), file("${coguk_id}.${run_name}.climb.bam") into publish_fasta_ch

    cpus 4
    memory '5 GB'

    """
    samtools view -h -F4 ${bam} | samtools sort -m1G -@ ${task.cpus} -o ${coguk_id}.${run_name}.climb.bam
    """
}

process publish_fasta {
    input:
    tuple username, dir, run_name, coguk_id, file(fasta), file(bam) from publish_fasta_ch

    output:
    publishDir path : "${params.publish}/fasta", pattern: "${coguk_id}.${run_name}.climb.fasta", mode: "copy", overwrite: true
    tuple username, dir, run_name, coguk_id, file("${coguk_id}.${run_name}.climb.fasta"), file(bam) into sorted_manifest_ch

    """
    cp ${fasta} ${coguk_id}.${run_name}.climb.fasta
    """
}

process samtools_depth {
    tag { bam }
    conda "environments/samtools.yaml"
    label 'bear'

    input:
    tuple username, dir, run_name, coguk_id, file(fasta), file(bam) from sorted_manifest_ch

    output:
    publishDir path: "${params.publish}/depth", pattern: "${coguk_id}.${run_name}.climb.bam.depth", mode: "copy", overwrite: true
    tuple username, dir, run_name, coguk_id, file(fasta), file(bam), file("${coguk_id}.${run_name}.climb.bam.depth") into swell_manifest_ch

    """
    samtools depth -d0 -a ${bam} > ${bam}.depth
    """
}

process swell {
    tag { bam }
    conda "environments/swell.yaml"
    label 'bear'

    input:
    tuple username, dir, run_name, coguk_id, file(fasta), file(bam), file(depth) from swell_manifest_ch

    output:
    publishDir path: "${params.publish}/qc", pattern: "${coguk_id}.${run_name}.qc", mode: "copy", overwrite: true
    tuple username, dir, run_name, coguk_id, file(fasta), file(bam), file("${coguk_id}.${run_name}.qc") into ocarina_file_manifest_ch
    file "${coguk_id}.${run_name}.qc" into report_ch

    """
    swell --ref 'NC_045512' 'NC045512' 'MN908947.3' --depth ${depth} --bed "${params.schemegit}/primer_schemes/nCoV-2019/V2/nCoV-2019.scheme.bed" --fasta "${fasta}" > ${coguk_id}.${run_name}.qc
    """

}

process ocarina_ls {
    input:
    tuple username, dir, run_name, coguk_id, file(fasta), file(bam), file(qc) from ocarina_file_manifest_ch

    output:
    file "${coguk_id}.${run_name}.ocarina" into ocarina_report_ch
    
    """
    echo "${coguk_id}\t${run_name}\t${username}\t${params.publish}\tfasta/${fasta}\talignment/${bam}\tqc/${qc}" > ${coguk_id}.${run_name}.ocarina
    """
}

ocarina_report_ch
    .collectFile(name: "ocarina.ls", storeDir: "${params.publish}/ocarina")

report_ch
    .collectFile(name: "test.qc", storeDir: "${params.publish}/qc", keepHeader: true)
