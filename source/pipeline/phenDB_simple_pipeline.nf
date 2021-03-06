#!/usr/bin/env nextflow

def help() {
    println """Required arguments:
    
               --inputfolder FOLDER    [The folder containing the fasta or tar.gz files to be processed]
               --outdir FOLDER        [The directory where the output folder should be generated]
               --accuracy_cutoff FLOAT [The level of computed accuracy below which pica results are not shown]
              
              Optional arguments (important: single dash):
              
               -profile [local, cluster] [Run the pipeline on local machine or on Slurm]
               -with-trace               [Create profile of nextflow run]
              
              Typical usage:
              nohup ./phenDB.nf --inputfolder <DIR> --workdir <DIR> --accuracy_cutoff <0-1> -profile local &> phenDB_output.log &
              
            """.stripIndent()
}


if ((!(params.inputfolder)) || (!(file(params.inputfolder).exists()))){
    help()
    exit 1, "Please specify an input folder containing the files to be processed."
}

jobname = file(params.inputfolder).getBaseName()
outdir = file(params.outdir)
file(outdir).mkdirs()
models = file(params.modelfolder).listFiles()
modelnames = Channel.fromPath("${params.modelfolder}/*", type: 'dir')
input_files = Channel.fromPath("${params.inputfolder}/*.fasta")
input_gzipfiles = Channel.fromPath("${params.inputfolder}/*.tar.gz")
input_barezipfiles = Channel.fromPath("${params.inputfolder}/*.zip")
all_input_files = Channel.fromPath("${params.inputfolder}/*")
hmmdb = file(params.hmmdb)
file("$outdir/logs").mkdirs()

log.info """
    ##################################################################################
    
    PhenDB Pipeline started.

    Input folder containing bin files (--inputfolder): $params.inputfolder
    Output directory: $outdir
    Job name: $jobname
    
    Disabled compute nodes (for hmmer computation) (--omit_nodes): $params.omit_nodes
    Accuracy cutoff for displaying PICA results (--accuracy_cutoff): $params.accuracy_cutoff

    ##################################################################################
    """.stripIndent()

// initialize filecount file
fastafilecount= file("$outdir/logs/fastafilecount.log")
fastafilecount.text = ""

// initialize error file for "sanity" errors (eg. corrupt fasta files)
errorfile= file("$outdir/logs/sanity_errors.log")
errorfile.text=""

// unzip tar.gz files
process tgz {

    input:
    file(tarfile) from input_gzipfiles

    output:
    file("${tarfile.getSimpleName()}/*.fasta") into tgz_unraveled_fasta
    file("${tarfile.getSimpleName()}/*") into tgz_unraveled_all

    script:
    outfolder = tarfile.getSimpleName()
    """
    tar -xf $tarfile
    mv ./*/ $outfolder 
    """
}

// unzip .zip files
process unzip {

    input:
    file(zipfile) from input_barezipfiles

    output:
    file("${zipfile.getSimpleName()}/*/*.fasta") into zip_unraveled_fasta
    file("${zipfile.getSimpleName()}/*/*") into zip_unraveled_all

    script:
    outfolder = zipfile.getSimpleName()
    """
    mkdir ${outfolder} && unzip ${zipfile} -d ${outfolder}
    """
}

// combine raw fasta files and those extracted from archive files
all_fasta_input_files = input_files.mix(tgz_unraveled_fasta.flatten(), zip_unraveled_fasta.flatten())
truly_all_input_files = all_input_files.mix(tgz_unraveled_all.flatten(), zip_unraveled_all.flatten())


// Error handling
truly_all_input_files.subscribe {

    //check if there are any non-fasta files
    if ((!(it.getName() ==~ /.+\.fasta$/ )) && (!(it.getName() =~ /.+\.tar.gz$/ )) && (!(it.getName() =~ /.+\.zip$/ ))){

        endingmess = "WARNING: the file ${it.getName()} does not end in '.fasta', '.zip' or '.tar.gz'.\n" +
                     "The file was dropped from the analysis.\n\n"
        log.info(endingmess)
        errorfile.append(endingmess)

    }
    //check if there are any files with non-ascii character names
    if (!( it.getBaseName() ==~ /^\p{ASCII}+$/ )) {

        asciimess = "WARNING: The filename of ${it.getName()} contains non-ASCII characters.\n" +
                    "The file was dropped from the analysis.\n\n"
        log.info(asciimess)
        errorfile.append(asciimess)
    }
}

// Passes every fasta file through Biopythons SeqIO to check for corrupted files
process fasta_sanity_check {
    errorStrategy 'ignore'

    input:
    file(item) from all_fasta_input_files

    output:
    set val(binname), file("sanitychecked.fasta") into fasta_sanitycheck_out

    script:
    binname = item.getName()
// language=Python
"""
#!/usr/bin/env python
from Bio import SeqIO
from Bio.Seq import Seq
from Bio.Alphabet import IUPAC
from Bio import Alphabet
import sys, os


with open("sanitychecked.fasta","w") as outfile:
    for read in SeqIO.parse("${item}", "fasta", IUPAC.ambiguous_dna):
        if not Alphabet._verify_alphabet(read.seq):
            with open("${errorfile}", "a") as myfile:
                myfile.write("WARNING: There was an unexpected DNA letter in the sequence of file ${binname}.\\n")
                myfile.write("Allowed letters are G,A,T,C,R,Y,W,S,M,K,H,B,V,D,N.\\n")
                myfile.write("The file was dropped from the analysis.\\n\\n")
            os.remove("sanitychecked.fasta")
            sys.exit("There was an unexpected letter in the sequence, aborting.")
        SeqIO.write(read, outfile, "fasta")
"""

}

// Print the number of valid fasta files to a file for progress display
fasta_sanitycheck_out.into { sanity_check_for_continue; sanity_check_for_count }
sanity_check_for_count.count().subscribe { fastafilecount.text=it }

process md5sum {

    tag { binname }

    input:
    set val(binname), file(item) from sanity_check_for_continue

    output:
    set val(binname), stdout, file(item) into md5_out

    script:
    """
    echo -n \$(md5sum ${item} | cut -f1 -d" ")
    """
}

// call prodigal for every sample in parallel
// output each result as a set of the sample id and the path to the prodigal outfile
process prodigal {

    tag { binname }

    module "prodigal"
    memory = "2 GB"

    input:
    set val(binname), val(mdsum), file(item) from md5_out

    output:
    set val(binname), val(mdsum), file("prodigalout.faa") into prodigalout

    script:
    """
    prodigal -i ${item} -a prodigalout.faa > /dev/null
    """
}

// call hmmer daemon for every sample in series
process hmmer {

    tag { binname }

    maxForks 1  //do not parallelize!
    module "hmmer"

    input:
    set val(binname), val(mdsum), file(item) from prodigalout

    output:
    set val(binname), val(mdsum), file("hmmer.out"), file(item) into hmmerout

    script:
    """
    DISABLED=\$(echo ${params.omit_nodes} | sed -e 's/\\([^ ]\\+\\)/-e &/g')
    if [[ -n "\$DISABLED" ]] ; then
        HMM_DAEMONCLIENTS=\$(echo cubeb{01..30} | tr " " "\\n" | grep -v \$(echo \$DISABLED) | tr "\\n" " ")
    else
        HMM_DAEMONCLIENTS=\$(echo cubeb{01..30})
    fi
    echo \$HMM_DAEMONCLIENTS
    
    hmmc.py -i ${item} -d $hmmdb -s \$HMM_DAEMONCLIENTS -n 100 -q 5 -m 1 -o hmmer.out
    """
}

// compute contamination and completeness using compleconta
process compleconta {

    tag { binname }
    module "muscle"
    module "compleconta/0.1"

    input:
    set val(binname), val(mdsum), file(hmmeritem), file(prodigalitem) from hmmerout

    output:
    set val(binname), val(mdsum), file(hmmeritem), file(prodigalitem), file("complecontaitem.txt") into complecontaout

    """
    compleconta.py $prodigalitem $hmmeritem | tail -1 > complecontaitem.txt
    """
}


complecontaout.into{complecontaout_continue; bin_to_db}

// compute accuracy from compleconta output and model intrinsics (once for each model).
process accuracy {

    tag { "${binname}_${model.getBaseName()}" }

    memory = '10 MB'
    errorStrategy 'ignore'  //model files not yet complete, TODO: remove this!!!!

    input:
    set val(binname), val(mdsum), file(hmmeritem), file(prodigalitem), file(complecontaitem) from complecontaout_continue
    each model from models

    output:
    set val(binname), val(mdsum), val(model), file(hmmeritem), file(prodigalitem), file(complecontaitem), stdout into accuracyout

    when:
    model.isDirectory() && (model.getBaseName() != "NOB")  // NOB accuracy file not valid atm

    script:
    RULEBOOK = model.getBaseName()
    ACCURACYFILE = "$model/${RULEBOOK}.accuracy"
    """
    python2 $params.balanced_accuracy_path $ACCURACYFILE $complecontaitem
    """
}

// call pica for every sample for every condition in parallel
process pica {

    tag { "${binname}_${model.getBaseName()}" }

    module 'pica'
    memory = '500 MB'

    input:
    set val(binname), val(mdsum), val(model), file(hmmeritem), file(prodigalitem), file(complecontaitem), val(accuracy) from accuracyout

    output:
    set val(binname), val(mdsum), val(RULEBOOK), stdout, val(accuracy) into picaout  //print decision on stdout, and put stdout into return set

    script:
    RULEBOOK = model.getBaseName()
    TEST_MODEL = "$model/${RULEBOOK}.rules"
    float accuracy_cutoff = params.accuracy_cutoff as float
    float accuracy_float = accuracy as float

    if (accuracy_float >= accuracy_cutoff) {
    """
    echo -ne "${binname}\t" > tempfile.tmp
    cut -f2 $hmmeritem | tr "\n" "\t" >> tempfile.tmp
    test.py -m $TEST_MODEL -t $RULEBOOK -s tempfile.tmp > picaout.result
    echo -n \$(cat picaout.result | tail -n1 | cut -f2,3)
    """
    }

    else {
    """
    echo -ne "${binname}\t" > tempfile.tmp
    cut -f2 $hmmeritem | tr "\n" "\t" >> tempfile.tmp
    echo "none\tN/A\tNA" > picaout.result
    echo -n \$(cat picaout.result | tail -n1 | cut -f2,3)
    """
    }
}

// merge all results into a file called $id.results and move each file to results folder.
picaout.into{pica_db_write; pica_out_write}

outfilechannel = pica_out_write.collectFile() { item ->
    [ "${item[0]}.results", "${item[2]}\t${item[3]}\t${item[4]}" ]  // use given bin name as filename
}.collect()


// create a matrix file containing all verdicts for each bin and add to output files
// create a matrix file containing summaries per model
// here we could for example add a header to each results file

process make_matrix_and_headers {

    stageInMode 'copy'

    input:
    file(allfiles) from outfilechannel
    val(m) from modelnames.toSortedList()

    output:
    file("*.{txt,tsv}") into all_files_for_tar

"""
#!/usr/bin/env python3

import datetime
import os
import glob

modelstring = "${m.join(" ")}"
cutoff = "${params.accuracy_cutoff}"
now = datetime.datetime.now().strftime("%Y/%m/%d %H:%M:%S")
HEADER = "Model_name\\tVerdict\\tProbability\\tBalanced_accuracy\\n"

modelvec = modelstring.split(" ")
modelvec = [os.path.basename(x) for x in modelvec]
modelvec = sorted(modelvec)
print(modelvec)

bin_dict = {}
countdict = {x: {"YES": 0, "NO": 0, "N/A": 0} for x in modelvec}
print(countdict)
resultmat = []

for name in glob.glob("*.results"):

    # extract info for matrix writing
    with open(os.path.join(os.getcwd(), name), "r") as binfile:
        binname = name.replace(".results", "")
        bin_dict[binname] = {}
        for line in binfile:
            sline = line.split()
            modelname, verdict = sline[0], sline[1]
            bin_dict[binname][modelname] = verdict
            countdict[modelname][verdict] += 1
    
        # sort results file and prepend header
        with open(os.path.join(os.getcwd(), name + ".txt"), "w") as sortfile:
            binfile.seek(0, 0)
            content = []
            for line in binfile:
                content.append(line.split())
            content = sorted(content, key=lambda x: x[0])
            sortfile.write(HEADER)
            for tup in content:
                sortfile.write("\\t".join(tup))
                sortfile.write("\\n")

countlist = []
for cond in ("YES", "NO", "N/A"):
    condlist = []
    for key, vals in countdict.items():
        condlist.append(vals[cond])
    countlist.append("\\t".join([cond] + [str(x) for x in condlist]))

with open("summary_matrix.results.tsv", "w") as outfile:
    outfile.write("# phenDB\\n# Time of run: {da}\\n# Accuracy cut-off: {co}\\n".format(da=now, co=cutoff))
    outfile.write("#\\nSummary of models:\\n")
    outfile.write("\\t".join([" "] + modelvec))
    outfile.write("\\n")
    for line in countlist:
        outfile.write(line)
        outfile.write("\\n")

with open("per_bin_matrix.results.tsv", "w") as outfile2:
    outfile2.write("# phenDB\\n# Time of run: {da}\\n# Accuracy cut-off: {co}\\n".format(da=now, co=cutoff))
    outfile2.write("\\n#Results per bin:\\n")
    outfile2.write("\\t".join([" "] + modelvec))
    outfile2.write("\\n")
    for item in bin_dict.keys():
        resultlist = []
        for modelname in modelvec:
            try:
                resultlist.append(bin_dict[item][modelname])
            except KeyError:
                resultlist.append("NC")
        outfile2.write("\\t".join([item] + resultlist))
        outfile2.write("\\n")
"""
}

process tar_results {

    tag { jobname }

    stageInMode 'copy'  //actually copy in the results so we not only tar symlinks

    input:
    file(allfiles) from all_files_for_tar
    file(errorfile)

    output:
    file("${jobname}.tar.gz") into tgz_to_db

    script:
    """
    mkdir -p ${jobname}/summaries
    cp ${errorfile} ${jobname}/summaries/input_errors.log
    mv *.results.tsv ${jobname}/summaries
    mv *.results.txt ${jobname}
    tar -cvf ${jobname}.tar.gz ./${jobname}
    rm -rf ${jobname}
    """
}

tgz_to_db.subscribe{ it.copyTo(outdir) }

workflow.onComplete {
    println "picaPipeline completed at: $workflow.complete"
    println "Execution status: ${ workflow.success ? 'OK' : 'failed' }"
}

workflow.onError {
    println "Pipeline has failed fatally with the error message: \n\n$workflow.errorMessage\n\n"
    println "Writing error report to directory ${outdir}/logs..."
    fatal_error_file = file("${outdir}/logs/errorReport.log")
    fatal_error_file.text = workflow.errorReport
}
