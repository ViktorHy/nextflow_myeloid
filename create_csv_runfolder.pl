#!/usr/bin/perl -w

use strict;


my $run_folder = "/fs1/seqdata/NovaSeq/200228_A00681_0081_AHKH2NDRXX/Data/Intensities/BaseCalls/";
opendir my $dh, $run_folder or die $!;

my %samples;
while (my $fastq = readdir $dh) {
    if ($fastq =~ /^\.+/) {
        next;
    }
    my @fastq = split/\_/,$fastq;
    $samples{$fastq[0]} = $fastq[1];
    
}


foreach my $sample (keys %samples) {
    my $outfile = "tmp/".$sample."AG.csv";
    open (OUT, '>', $outfile);
    print OUT "group,id,type,read1,read2\n";
    my $read1 = "$run_folder/$sample"."_$samples{$sample}"."_R1_001.fastq.gz";
    my $read2 = "$run_folder/$sample"."_$samples{$sample}"."_R2_001.fastq.gz";
    print OUT "$sample,$sample,tumor,$read1,$read2";
    close OUT;
}
