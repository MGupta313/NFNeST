#!/usr/bin/env nextflow
BBDUK = file(params.input.bbduk)
params.reads = params.input.fastq_path+'/SRR*_{1,2}.fastq'
fastq_path = Channel.fromFilePairs(params.reads, size: -1)
/*fastq_path.view()*/
fasta_path = Channel.fromPath(params.input.fasta_path)
out_path = Channel.fromPath(params.output.folder)
bed_path = Channel.fromPath(params.input.bed_path)
variant_path = Channel.fromPath(params.input.variant_path)
bbduk_path = "$params.input.bbduk_def"
params.genome = "$baseDir/ref/pfalciparum/mdr.fa"
params.bed = "$baseDir/ref⁩/pfalciparum⁩/mdr.bed"
params.fas = "$baseDir/ref/pfalciparum/adapters.fa"
params.gatk= "$baseDir/gatk-4.1.9.0/gatk"
mode = "$params.input.mode"
vcfmode = "$params.input.vcfmode"

process combineFastq {
    publishDir "$params.output.folder/trimFastq/${pair_id}", pattern: "*.fastq", mode : "copy"
    input:
        set pair_id, path(fastq_group) from fastq_path

    
    output:
        tuple val(pair_id), path("${pair_id}_R1.fastq"), path("${pair_id}_R2.fastq") into comb_out

    script:
        """
        cat *1.fastq > ${pair_id}_R1.fastq
        cat *2.fastq > ${pair_id}_R2.fastq
        """
}

comb_out.into{preqc_path; trim_path}

process preFastQC {
    publishDir "$params.output.folder/preFastqQC/${sample}", mode : "copy"
    input:
        set val(sample), path(read_one), path(read_two) from preqc_path
    
    output:
        tuple val(sample), path("*") into preqc_out
    
    script:
        """
        fastqc --extract -f fastq -o ./ -t $task.cpus ${read_one} ${read_two}
        """
}

process trimFastq {
    publishDir "$params.output.folder/trimFastq/${sample}", pattern: "*.fastq", mode : "copy"
    publishDir "$params.output.folder/trimFastq/${sample}/Stats", pattern: "*.txt", mode : "copy"
    input:
        set val(sample), path(read_one), path(read_two) from trim_path
        path fas from params.fas
    
    output:
        tuple val(sample), path("${sample}_trimmed_R1.fastq"), path("${sample}_trimmed_R2.fastq"), path("${sample}_*.txt") into trim_out

    script:
        """
        bbduk.sh -Xmx1g k=27 hdist=1 edist=1 ktrim=l in=${read_one} in2=${read_two} \\
        out=${sample}_trimmed_R1.fastq ref=${fas} \\
        qtrim=rl minlength=50 \\
        out2=${sample}_trimmed_R2.fastq stats=${sample}_stats.txt 
        """
}

trim_out.into{align_path; postqc_path}

process postFastQC {
    publishDir "$params.output.folder/postFastqQC/${sample}", mode : "copy"
    input:
        set val(sample), path(read_one), path(read_two), path(stats_path) from postqc_path
    
    output:
        tuple val(sample), path("*") into postqc_out
    
    script:
        """
        fastqc --extract -f fastq -o ./ -t $task.cpus ${read_one} ${read_two}
        """
}

process buildIndex {
    tag "$genome.baseName"
    publishDir "$params.output.folder/Bowtie2Index", mode : "copy"

    input:
    path genome from params.genome

    output:
    file 'genome.index*' into index_ch

    script:
    if( mode == 'Bowtie')
    """
    bowtie2-build ${genome} genome.index
    """
}



process alignReads {
    publishDir "$params.output.folder/alignedReads/${sample}", pattern: "*.sam", mode : "copy"
    publishDir "$params.output.folder/alignedReads/${sample}/Stats", pattern: "*.txt", mode : "copy"
    input:
        set val(sample), path(read_one), path(read_two), path(stats_path) from align_path
        file index from index_ch
        path genome from params.genome
    
    output:
        tuple val(sample), path("${sample}.sam"), path("${sample}_bmet.txt") into align_out

    script:
        index_base = index[0].toString() - ~/.rev.\d.bt2?/ - ~/.\d.bt2?/
        if( mode == 'Bowtie')
            """
            bowtie2 --very-sensitive  --dovetail --met-file ${sample}_bmet.txt -p $task.cpus \\
            -x $baseDir/$params.output.folder/Bowtie2Index/$index_base \\
            -1 ${read_one} -2 ${read_two} -p 4 -S ${sample}.sam 
            """
        else if( mode == 'Bwa' )
            """
            bwa mem -t 4 ${genome} ${read_one} ${read_two} > ${sample}.sam 
            """
        else if( mode == 'BBMap' )
            """
            bbmap ref=${genome} in=${read_one} in2=${read_two} out=${sample}.sam 
            """
        else if( mode == 'Snap' )
            """
            snap paired ${genome} ${read_one} ${read_two} -t 4 -o -sam ${sample}.sam $task.cpus \\
            """
}

process processAlignments {
    publishDir "$params.output.folder/alignedReads/${sample}", pattern: "*.ba*", mode : "copy"
    input:
        set val(sample), path(sam_path), path(align_met) from align_out
        path genome from params.genome
    
    output:
        tuple val(sample), path("${sample}_SR.bam") into postal_out
        tuple val(sample), path("${sample}_SR.bam") into postal_out2
        tuple val(sample), path("${sample}_SR.bam") into postal_out3
        tuple val(sample), path("${sample}_SR.bam") into postal_out4

    script:
        """
        java -jar $baseDir/picard.jar AddOrReplaceReadGroups -I ${sam_path} -O ${sample}_SR.bam -SORT_ORDER coordinate --CREATE_INDEX true \\
        -LB ExomeSeq -DS ExomeSeq -PL Illumina -CN AtlantaGenomeCenter -DT 2016-08-24 -PI null -ID ${sample} \\
        -PG ${sample} -PM ${sample} -SM ${sample} -PU HiSeq2500
        """
    
}

process GenerateVCFSam {
    publishDir "$params.output.folder/GenerateVCFSam/${sample}", pattern: "*.vcf", mode : "copy"
    input:
        set val(sample), path(bam_path) from postal_out
        path genome from params.genome

    output:
        tuple val(sample), path("${sample}-1.vcf") into vcf_out1

    script:
        """
        bcftools mpileup -f ${genome} ${bam_path} > ${sample}.mpileup
        bcftools call -vm ${sample}.mpileup > ${sample}-1.vcf
        """
}

process GenerateVCFHap {
    publishDir "$params.output.folder/GenerateVCFHap/${sample}", pattern: "*.vcf", mode : "copy"
    input:
        set val(sample), path(bam_path) from postal_out2
        path genome from params.genome
        path gatk from params.gatk

    output:
        tuple val(sample), path("${sample}-2.vcf") into vcf_out2

    script:
        """
        $baseDir/gatk-4.1.9.0/gatk HaplotypeCaller -R $baseDir/ref/pfalciparum/mdr.fa -I ${bam_path} -O ${sample}-2.vcf
        """
}

process GenerateVCFHFree {
    publishDir "$params.output.folder/GenerateVCFFree/${sample}", pattern: "*.vcf", mode : "copy"
    input:
        set val(sample), path(bam_path) from postal_out3
        path genome from params.genome
        path gatk from params.gatk

    output:
        tuple val(sample), path("${sample}-3.vcf") into vcf_out3

    script:
        """
        freebayes -f ${genome} ${bam_path} > ${sample}-3.vcf
        """
}

process merge {
    publishDir "$params.output.folder/final_vcf/${sample}", mode : "copy"

    input:
        set val(sample), path(vcf_path1) from vcf_out1
        set val(sample), path(vcf_path2) from vcf_out2
        set val(sample), path(vcf_path3) from vcf_out3
        set val(sample), path(bam_path) from postal_out4

    output:
        tuple val(sample), path("final_${sample}.vcf") into anno_out

    script:
        """
        samtools index ${bam_path}
        python $baseDir/annotate.py -r $baseDir/mdr.fa -b $baseDir/mdr.bed -o ${sample} -v1 ${vcf_path1} -v2 ${vcf_path2} -v3 ${vcf_path3} -m ${bam_path} -voi $baseDir/ref/pfalciparum/Reportable_SNPs.csv -name ${sample}
        """
}