#!/usr/bin/env python3
import os
import os.path
import threading
from phenotypePredictionApp.models import UploadedFile
from redis import Redis
from rq import Queue
from businessLogic.enqueue_job import phenDB_enqueue

class startProcessThread(threading.Thread):
    def __init__(self, keyname):
        threading.Thread.__init__(self)
        self.keyname = keyname

    def run(self):
        print('startProcess called')

        # ppath = "/apps/phenDB/source/web_server:$PYTHONPATH"
        # web_server_folder = "/apps/phenDB/source/web_server"
        # pipeline_path = "/apps/phenDB/source/pipeline/picaPipeline.nf"
        # above_workfolder = "/apps/phenDB/source/web_server/results/resultFiles"

        ppath = "/apps/phenDB_devel_LL/source/web_server:$PYTHONPATH"
        web_server_folder = "/apps/phenDB_devel_LL/source/web_server"
        pipeline_path = "/apps/phenDB_devel_LL/source/pipeline/picaPipeline.nf"
        above_workfolder = "/apps/phenDB_devel_LL/data/results"

        # ppath = "/apps/phenDB_devel_PP/phenDB/source/web_server:$PYTHONPATH"
        # web_server_folder = "/apps/phenDB_devel_PP/phenDB/source/web_server"
        # pipeline_path = "/apps/phenDB_devel_PP/phenDB/source/pipeline/picaPipeline.nf"
        # above_workfolder = "/apps/phenDB_devel_PP/phenDB/source/web_server/results/resultFiles"

        relFilePath = os.path.dirname(UploadedFile.objects.get(key=self.keyname).fileInput.url)
        infolder = os.path.join(str(web_server_folder), str(relFilePath)[1:])
        print("infolder:", infolder)

        pica_cutoff = "0.5"
        node_offs = ""

        os.environ["DJANGO_SETTINGS_MODULE"] = "phenotypePrediction.settings"
        os.environ["PYTHONPATH"] = ppath

        # create workfolder
        outfolder = os.path.join(above_workfolder, "{jn}_results".format(jn=self.keyname))
        os.makedirs(outfolder, exist_ok=True)

        # create log folder
        logfolder = os.path.join(outfolder, "logs")
        os.makedirs(logfolder)

        # add the function call to the redis queue
        q = Queue('phenDB', connection=Redis())
        pipeline_job = q.enqueue_call(func=phenDB_enqueue,
                                      args=(ppath, pipeline_path, infolder, outfolder, pica_cutoff, node_offs),
                                      timeout=5000,
                                      job_id=self.keyname
                                      )
        #return pipeline_job
        # here we could return len(q). or fetch it somewhere else. We could also set errors in the DB.