#!/usr/bin/env bash

BASEDIR="/apps/phenDB_devel_HP"
DB="phenDB_trex"

export PYTHONPATH="$BASEDIR/source/web_server:$PYTHONPATH"
export DJANGO_SETTINGS_MODULE="phenotypePrediction.settings"
