#!/usr/bin/env python3
#
# Created by Lukas Lüftinger on 08/05/2018.
#
import os
import sys
import shutil
import ftplib
import tempfile
from time import sleep

import django
from Bio import Entrez
from datetime import date, timedelta
from redis import Redis
from rq import Queue

from phenotypePredictionApp.variables import PHENDB_BASEDIR, PHENDB_QUEUE, PHENDB_DEBUG
from enqueue_job import phenDB_enqueue

Entrez.email = "test@test.com"
DAYS_BACK = 60


def get_latest_refseq_genomes(n_days):
    records = []
    minus_n_days = date.today() - timedelta(days=n_days)
    dateformatted = minus_n_days.strftime("%Y/%m/%d")
    todayformatted = date.today().strftime("%Y/%m/%d")
    search_string = 'bacteria[filter] ' \
                    'AND ("reference genome"[filter] OR "representative genome"[filter]) ' \
                    'AND ("{minus}"[SeqReleaseDate] : "{today}"[SeqReleaseDate])'.format(minus=dateformatted,
                                                                                         today=todayformatted)
    with Entrez.esearch(db="assembly", term=search_string, retmax=None) as handle:
        record = Entrez.read(handle)
    idlist = record["IdList"]
    for i in idlist:
        try:
            with Entrez.esummary(db="assembly", id=i) as summary_handle:
                summary = Entrez.read(summary_handle, validate=False)
                summarydict = summary["DocumentSummarySet"]["DocumentSummary"][-1]
                taxid = summarydict["Taxid"]
                name = summarydict["SpeciesName"]
                assembly_id = summarydict["LastMajorReleaseAccession"]
                ftppath = summarydict["FtpPath_RefSeq"]
                if ftppath != "":
                    records.append((name, taxid, assembly_id, ftppath))
        except:
            continue
    return records


def download_genomes(los, path):
    if os.path.exists(path):
        shutil.rmtree(path)
    with tempfile.TemporaryDirectory() as tmpname:
        for name, taxid, assembly_id, ftppath in los:
            ftp = ftplib.FTP("ftp.ncbi.nlm.nih.gov", "anonymous", "password")
            restpath = "/".join(ftppath.split("/")[3:])
            ftp.cwd("/{rp}".format(rp=restpath))
            genomicfile = [x for x in ftp.nlst() if "genomic.fna.gz" in x and "from" not in x][0]
            if not genomicfile:
                continue
            fullpath_local = os.path.join(tmpname, genomicfile)
            with open(fullpath_local, "wb") as outfile:
                ftp.retrbinary("RETR {file}".format(file=genomicfile), outfile.write)
            shutil.move(fullpath_local, os.path.join(tmpname, "PHENDB_PRECALC_" + assembly_id + ".fna.gz"))
        shutil.copytree(tmpname, path)


def check_add_precalc_job():
    from phenotypePredictionApp.models import Job
    try:
        Job.objects.get(key="PHENDB_PRECALC")
    except:
        new_precalc_job = Job(key="PHENDB_PRECALC")
        new_precalc_job.save()


def add_taxids_to_precalc_bins(los):
    from phenotypePredictionApp.models import Bin, Job
    for name, taxid, assembly_id, ftppath in los:
        binname = "PHENDB_PRECALC_" + assembly_id + ".genomic.fna.gz"
        givenbin = Bin.objects.filter(bin_name=binname)
        if not givenbin:
            raise RuntimeError("Bin not found in database.")
        givenbin.update(tax_id=str(taxid), assembly_id=str(assembly_id), taxon_name="", taxon_rank="")


def main():
    ppath = PHENDB_BASEDIR + "/source/web_server:$PYTHONPATH"
    infolder = os.path.join(PHENDB_BASEDIR, "data/uploads/PHENDB_PRECALC")
    outfolder = os.path.join(PHENDB_BASEDIR, "data/results/PHENDB_PRECALC_results")
    logfolder = os.path.join(outfolder, "logs")
    pipeline_path = os.path.join(PHENDB_BASEDIR, "source/pipeline/picaPipeline.nf")

    os.environ["DJANGO_SETTINGS_MODULE"] = "phenotypePrediction.settings"
    os.environ["PYTHONPATH"] = ppath
    django.setup()

    os.makedirs(outfolder, exist_ok=True)
    os.makedirs(logfolder, exist_ok=True)

    print("Downloading newest genomes from RefSeq...")
    gtlist = get_latest_refseq_genomes(n_days=DAYS_BACK)
    if len(gtlist) == 0:
        print("No new genomes found.")
        sys.exit(0)
    download_genomes(los=gtlist, path=infolder)

    print("Submitting precalculation job. Bins in folder {inf} will be added to the database.".format(inf=infolder))
    check_add_precalc_job()
    q = Queue(PHENDB_QUEUE, connection=Redis())
    pipeline_call = q.enqueue_call(func=phenDB_enqueue,
                                   args=(ppath, pipeline_path, infolder, outfolder, 0.5, ""),
                                   timeout='72h',
                                   ttl='72h',
                                   job_id="PHENDB_PRECALC"
                                   )
    while pipeline_call.result is None:
        sleep(10)

    if pipeline_call.result is 0:
        print("Precalculation was successful.")
        print("Adding taxonomic information to precalculated bins.")
        add_taxids_to_precalc_bins(gtlist)
        print("Finished. added {lolos} items to database.".format(lolos=len(gtlist)))


if __name__ == "__main__":
    main()
