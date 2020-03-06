#!/usr/bin/env nextflow

genome_file = file(params.genome_file)

OUTDIR = params.outdir+'/'+params.subdir

csv = file(params.csv)
mode = csv.countLines() > 2 ? "paired" : "unpaired"
println(mode)



Channel
    .fromPath(params.csv).splitCsv(header:true)
    .map{ row-> tuple(row.group, row.id, row.type, file(row.read1), file(row.read2)) }
    .into { fastq_umi; fastq_noumi }

Channel
    .fromPath(params.csv).splitCsv(header:true)
    .map{ row-> tuple(row.group, row.id, row.type) }
    .set { meta_aggregate }



// Split bed file in to smaller parts to be used for parallel variant calling
Channel
    .fromPath("${params.regions_bed}")
    .ifEmpty { exit 1, "Regions bed file not found: ${params.regions_bed}" }
    .splitText( by: 200, file: 'bedpart.bed' )
    .into { beds_mutect; beds_freebayes; beds_tnscope; beds_vardict }



process bwa_umi {
	publishDir "${OUTDIR}/bam", mode: 'copy', overwrite: true
	cpus params.cpu_all
	memory '64 GB'
	time '2h'

	input:
		set group, id, type, file(r1), file(r2) from fastq_umi

	output:
		set group, id, type, file("${id}.${type}.bwa.umi.sort.bam"), file("${id}.${type}.bwa.umi.sort.bam.bai") into bam_umi_bqsr, bam_umi_confirm
		set group, id, type, file("${id}.${type}.bwa.umi.sort.bam"), file("${id}.${type}.bwa.umi.sort.bam.bai"), file("dedup_metrics.txt") into bam_umi_qc

	when:
		params.umi

	"""
	sentieon umi extract -d 3M2S+T,3M2S+T $r1 $r2 \\
	|sentieon bwa mem \\
		-R "@RG\\tID:$id\\tSM:$id\\tLB:$id\\tPL:illumina" \\
		-t ${task.cpus} \\
		-p -C $genome_file - \\
	|sentieon umi consensus -o consensus.fastq.gz

	sentieon bwa mem \\
		-R "@RG\\tID:$id\\tSM:$id\\tLB:$id\\tPL:illumina" \\
		-t ${task.cpus} \\
		-p -C $genome_file consensus.fastq.gz \\
	|sentieon util sort -i - \\
		-o ${id}.${type}.bwa.umi.sort.bam \\
		--sam2bam

	touch dedup_metrics.txt
	"""
}


process bwa_align {
	cpus params.cpu_all
	publishDir "${OUTDIR}/bam", mode: 'copy', overwrite: true
	memory '64 GB'
	time '2h'
	    
	input: 
		set group, id, type, file(r1), file(r2) from fastq_noumi

	output:
		set group, id, type, file("${id}.${type}.bwa.sort.bam"), file("${id}.${type}.bwa.sort.bam.bai") into bam_markdup

	when:
		!params.umi

	script:

		if( params.sentieon_bwa ) {
			"""
			sentieon bwa mem -M -R '@RG\\tID:${id}\\tSM:${id}\\tPL:illumina' -t ${task.cpus} $genome_file $r1 $r2 \\
			| sentieon util sort -r $genome_file -o ${id}.${type}.bwa.sort.bam -t ${task.cpus} --sam2bam -i -
			"""
		}

		else {
			"""
			bwa mem -R '@RG\\tID:${id}\\tSM:${id}\\tPL:illumina' -M -t ${task.cpus} $genome_file $r1 $r2 \\
			| samtools view -Sb - \\
			| samtools sort -o ${id}.${type}.bwa.sort.bam -

			samtools index ${id}.${type}.bwa.sort.bam
			"""
		}
}


process markdup {
	publishDir "${OUTDIR}/bam", mode: 'copy', overwrite: true
	cpus params.cpu_many
	memory '64 GB'
	time '1h'
    
	input:
		set group, id, type, file(bam), file(bai) from bam_markdup

	output:
		set group, id, type, file("${id}.${type}.dedup.bam"), file("${id}.${type}.dedup.bam.bai") into bam_bqsr
		set group, id, type, file("${id}.${type}.dedup.bam"), file("${id}.${type}.dedup.bam.bai"), file("dedup_metrics.txt") into bam_qc

	"""
	sentieon driver -t ${task.cpus} -i $bam --algo LocusCollector --fun score_info score.gz
	sentieon driver -t ${task.cpus} -i $bam --algo Dedup --score_info score.gz --metrics dedup_metrics.txt ${id}.${type}.dedup.bam
	sentieon driver -t ${task.cpus} -r $genome_file -i ${id}.${type}.dedup.bam --algo QualCal ${id}.bqsr.table
	"""
}


process bqsr {
	cpus params.cpu_some
	memory '16 GB'
	time '1h'

	input:
		set group, id, type, file(bam), file(bai) from bam_bqsr.mix(bam_umi_bqsr)

	output:
		set group, id, type, file(bam), file(bai), file("${id}.bqsr.table") into bam_freebayes, bam_vardict, bam_tnscope, bam_pindel, bam_cnvkit

	"""
	sentieon driver -t ${task.cpus} -r $genome_file -i $bam --algo QualCal ${id}.bqsr.table
	"""
}


process sentieon_qc {
	cpus params.cpu_many
	memory '32 GB'
	publishDir "${OUTDIR}/QC", mode: 'copy', overwrite: 'true'
	time '1h'

	input:
		set group, id, type, file(bam), file(bai), file(dedup) from bam_qc.mix(bam_umi_qc)

	output:
		set group, id, type, file("${id}_is_metrics.txt") into insertsize_pindel
		set id, file("${id}_${type}.QC")

	"""
	sentieon driver \\
		--interval $params.regions_bed -r $genome_file -t ${task.cpus} -i ${bam} \\
		--algo MeanQualityByCycle mq_metrics.txt --algo QualDistribution qd_metrics.txt \\
		--algo GCBias --summary gc_summary.txt gc_metrics.txt --algo AlignmentStat aln_metrics.txt \\
		--algo InsertSizeMetricAlgo is_metrics.txt \\
		--algo CoverageMetrics --cov_thresh 1 --cov_thresh 10 --cov_thresh 30 --cov_thresh 100 --cov_thresh 250 --cov_thresh 500 cov_metrics.txt
	sentieon driver \\
		-r $genome_file -t ${task.cpus} -i ${bam} \\
		--algo HsMetricAlgo --targets_list $params.interval_list --baits_list $params.interval_list hs_metrics.txt
	cp is_metrics.txt ${id}_is_metrics.txt
	qc_sentieon.pl ${id}_${type} panel > ${id}_${type}.QC
	"""
}


process freebayes {
	cpus 1
	time '20m'
	
	input:
		set group, id, type, file(bams), file(bais), file(bqsr) from bam_freebayes.groupTuple()
		each file(bed) from beds_freebayes

	output:
		set val("freebayes"), group, file("freebayes_${bed}.vcf") into vcfparts_freebayes

	when:
		params.freebayes

	script:
		if( mode == "paired" ) {

			tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }
			normal_idx = type.findIndexOf{ it == 'normal' || it == 'N' }

			"""
			freebayes -f $genome_file -t $bed --pooled-continuous --pooled-discrete --min-repeat-entropy 1 -F 0.03 ${bams[tumor_idx]} ${bams[normal_idx]} > freebayes_${bed}.vcf.raw
			vcffilter -F LowCov -f "DP > 500" -f "QA > 1500" freebayes_${bed}.vcf.raw | vcffilter -F LowFrq -o -f "AB > 0.05" -f "AB = 0" | vcfglxgt > freebayes_${bed}.filt1.vcf
			filter_freebayes_somatic.pl freebayes_${bed}.filt1.vcf ${id[tumor_idx]} ${id[normal_idx]} > freebayes_${bed}.vcf
			"""
		}
		else if( mode == "unpaired" ) {
			"""
			freebayes -f $genome_file -t $bed --pooled-continuous --pooled-discrete --min-repeat-entropy 1 -F 0.03 $bams > freebayes_${bed}.vcf
			"""
		}
}


process vardict {
	cpus 1
	time '20m'

	input:
		set group, id, type, file(bams), file(bais), file(bqsr) from bam_vardict.groupTuple()
		each file(bed) from beds_vardict

	output:
		set val("vardict"), group, file("vardict_${bed}.vcf") into vcfparts_vardict

	when:
		params.vardict
    
	script:
		if( mode == "paired" ) {

			tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }
			normal_idx = type.findIndexOf{ it == 'normal' || it == 'N' }

			"""
			vardict-java -G $genome_file -f 0.01 -N ${id[tumor_idx]} -b "${bams[tumor_idx]}|${bams[normal_idx]}" -c 1 -S 2 -E 3 -g 4 $bed \\
			| testsomatic.R | var2vcf_paired.pl -N "${id[tumor_idx]}|${id[normal_idx]}" -f 0.01 > vardict_${bed}.vcf.raw

			filter_vardict_somatic.pl vardict_${bed}.vcf.raw ${id[tumor_idx]} ${id[normal_idx]} > vardict_${bed}.vcf
			"""
		}
		else if( mode == "unpaired" ) {
			"""
			vardict-java -G $genome_file -f 0.03 -N $id -b $bams -c 1 -S 2 -E 3 -g 4 $bed | teststrandbias.R | var2vcf_valid.pl -N $id -E -f 0.01 > vardict_${bed}.vcf
			"""
		}
}


process tnscope {
	cpus params.cpu_some
	time '1h'    

	input:
		set group, id, type, file(bams), file(bais), file(bqsr) from bam_tnscope.groupTuple()
		each file(bed) from beds_tnscope

	output:
		set val("tnscope"), group, file("tnscope_${bed}.vcf") into vcfparts_tnscope

	when:
		params.tnscope

	script:
		tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }
		normal_idx = type.findIndexOf{ it == 'normal' || it == 'N' }

		if( mode == 'paired' ) {
			"""
			sentieon driver -t ${task.cpus} \\
				-r $genome_file \\
				-i ${bams[tumor_idx]} -q ${bqsr[tumor_idx]} \\
				-i ${bams[normal_idx]} -q ${bqsr[normal_idx]} \\
				--interval $bed --algo TNscope \\
				--tumor_sample ${id[tumor_idx]} --normal_sample ${id[normal_idx]} \\
				--clip_by_minbq 1 --max_error_per_read 3 --min_init_tumor_lod 2.0 \\
				--min_base_qual 10 --min_base_qual_asm 10 --min_tumor_allele_frac 0.0005 \\
				tnscope_${bed}.vcf.raw

			filter_tnscope_somatic.pl tnscope_${bed}.vcf.raw ${id[tumor_idx]} ${id[normal_idx]} > tnscope_${bed}.vcf

			"""
		}
		else {
			"""
			sentieon driver -t ${task.cpus} -r $genome_file \\
				-i ${bams} -q ${bqsr} \\
				--interval $bed --algo TNscope \\
				--tumor_sample ${id[0]} \\
				--clip_by_minbq 1 --max_error_per_read 3 --min_init_tumor_lod 2.0 \\
				--min_base_qual 10 --min_base_qual_asm 10 --min_tumor_allele_frac 0.00005 \\
				tnscope_${bed}.vcf
			""" 
		}
}


process pindel {
	cpus params.cpu_some
	time '30 m'
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: true

	input:
		set group, id, type, file(bams), file(bais), file(bqsr), file(ins_size) from bam_pindel.join(insertsize_pindel, by:[0,1,2]).groupTuple()

	output:
		set group, val("pindel"), file("${group}_pindel.vcf") into vcf_pindel

	when:
		params.pindel

	script:
		if( mode == "paired" ) {
			tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }
			normal_idx = type.findIndexOf{ it == 'normal' || it == 'N' }
			ins_tumor = ins_size[tumor_idx]
			ins_normal = ins_size[normal_idx]
			bam_tumor = bams[tumor_idx]
			bam_normal = bams[normal_idx]
			id_tumor = id[tumor_idx]
			id_normal = id[normal_idx]

			"""
			INS_T="\$(sed -n '3p' $ins_tumor | cut -f 1 | awk '{print int(\$1+0.5)}')"
			INS_N="\$(sed -n '3p' $ins_normal | cut -f 1 | awk '{print int(\$1+0.5)}')"
			echo "$bam_tumor\t\$INS_T\t$id_tumor" > pindel_config
			echo "$bam_normal\t\$INS_N\t$id_normal" >> pindel_config

			pindel -f $genome_file -w 0.1 -x 2 -i pindel_config -j $params.pindel_regions_bed -o tmpout -T ${task.cpus}
			pindel2vcf -P tmpout -r $genome_file -R hg19 -d 2015-01-01 -v ${group}_pindel_unfilt.vcf -is 10 -e 30 -he 0.01
			filter_pindel_somatic.pl ${group}_pindel_unfilt.vcf ${group}_pindel.vcf
			"""
		}
		else {
			tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }
			ins_tumor = ins_size[tumor_idx]
			bam_tumor = bams[tumor_idx]
			id_tumor = id[tumor_idx]

			"""
			INS_T="\$(sed -n '3p' $ins_tumor | cut -f 1 | awk '{print int(\$1+0.5)}')"
			echo "$bam_tumor\t\$INS_T\t$id_tumor" > pindel_config

			pindel -f $genome_file -w 0.1 -x 2 -i pindel_config -j $params.pindel_regions_bed -o tmpout -T ${task.cpus}
			pindel2vcf -P tmpout -r $genome_file -R hg19 -d 2015-01-01 -v ${group}_pindel_unfilt.vcf -is 10 -e 30 -he 0.01
			filter_pindel_somatic.pl ${group}_pindel_unfilt.vcf ${group}_pindel.vcf
			"""
		}

}


// Prepare vcf parts for concatenation
vcfparts_freebayes = vcfparts_freebayes.groupTuple(by:[0,1])
vcfparts_tnscope   = vcfparts_tnscope.groupTuple(by:[0,1])
vcfparts_vardict   = vcfparts_vardict.groupTuple(by:[0,1])
vcfs_to_concat = vcfparts_freebayes.mix(vcfparts_vardict).mix(vcfparts_tnscope)

process concatenate_vcfs {
	cpus 1
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: true
	time '20m'    

	input:
		set vc, group, file(vcfs) from vcfs_to_concat

	output:
		set group, vc, file("${group}_${vc}.vcf.gz") into concatenated_vcfs, vcf_cnvkit

	"""
	vcf-concat $vcfs | vcf-sort -c | gzip -c > ${vc}.concat.vcf.gz
	vt decompose ${vc}.concat.vcf.gz -o ${vc}.decomposed.vcf.gz
	vt normalize ${vc}.decomposed.vcf.gz -r $genome_file | vt uniq - -o ${group}_${vc}.vcf.gz
	"""
}


process cnvkit {
	cpus 1
	time '1h'
	publishDir "${OUTDIR}/plots", mode: 'copy', overwrite: true
	
	input:
		set gr, id, type, file(bam), file(bai), file(bqsr), g, vc, file(vcf) from bam_cnvkit.combine(vcf_cnvkit.filter { item -> item[1] == 'freebayes' })
		
	output:
		file("${gr}.${id}.cnvkit.png")

	when:
		params.cnvkit

	script:
		freebayes_idx = vc.findIndexOf{ it == 'freebayes' }

		"""
		cnvkit.py batch $bam -r $params.cnvkit_reference -d results/
		cnvkit.py scatter -s results/*.cn{s,r} -o ${gr}.${id}.cnvkit.png -v ${vcf[freebayes_idx]} -i $id
		"""
}


process aggregate_vcfs {
	cpus 1
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: true
	time '20m'

	input:
		set group, vc, file(vcfs) from concatenated_vcfs.mix(vcf_pindel).groupTuple()
		set g, id, type from meta_aggregate.groupTuple()

	output:
		set group, file("${group}.agg.vcf") into vcf_vep

	script:
		sample_order = id[0]
		if( mode == "paired" ) {
			tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }
			normal_idx = type.findIndexOf{ it == 'normal' || it == 'N' }
			sample_order = id[tumor_idx]+","+id[normal_idx]
		}

		"""
		aggregate_vcf.pl --vcf ${vcfs.sort(false) { a, b -> a.getBaseName() <=> b.getBaseName() }.join(",")} --sample-order ${sample_order} |vcf-sort -c > ${group}.agg.vcf
		"""
}


process annotate_vep {
	container = '/fs1/resources/containers/container_VEP.sif'
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: true
	cpus params.cpu_many
	time '1h'
    
	input:
		set group, file(vcf) from vcf_vep

	output:
		set group, file("${group}.vep.vcf") into vcf_umi

	"""
	vep -i ${vcf} -o ${group}.vep.vcf \\
	--offline --merged --everything --vcf --no_stats \\
	--fork ${task.cpus} \\
	--force_overwrite \\
	--plugin CADD $params.CADD --plugin LoFtool \\
	--fasta $params.VEP_FASTA \\
	--dir_cache $params.VEP_CACHE --dir_plugins $params.VEP_CACHE/Plugins \\
	--distance 200 \\
	-cache -custom $params.GNOMAD \\
	"""
}


process umi_confirm {
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: true
	cpus 1
	time '4h'

	input:
		set group, file(vcf) from vcf_umi
		set g, id, type, file(bam), file(bai) from bam_umi_confirm.groupTuple()

	output:
		file("${group}.vep.umi.vcf")


	when:
		params.umi

	script:
		if( mode == "paired" ) {
			tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }
			normal_idx = type.findIndexOf{ it == 'normal' || it == 'N' }

			"""
			source activate samtools
			UMIconfirm_vcf.py ${bam[tumor_idx]} $vcf $genome_file ${id[tumor_idx]} > umitmp.vcf
			UMIconfirm_vcf.py ${bam[normal_idx]} umitmp.vcf $genome_file ${id[normal_idx]} > ${group}.vep.umi.vcf
			"""
		}
		else if( mode == "unpaired" ) {
			tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }

			"""
			source activate samtools
			UMIconfirm_vcf.py ${bam[tumor_idx]} $vcf $genome_file ${id[tumor_idx]} > ${group}.vep.umi.vcf
			"""
		}
}
