#!/usr/bin/bash
source ~/.path
source ~/.ocarina
cd $ELAN_SOFTWARE_DIR

MSG='{"text":"*COG-UK inbound pipeline begins...*
_HERE WE GO!_"}'
curl -X POST -H 'Content-type: application/json' --data "$MSG" $SLACK_MGMT_HOOK

DATESTAMP=$1
echo $DATESTAMP

# OCARINA_FILE only written if elan processed at least one sample
OCARINA_FILE="$ELAN_DIR/staging/summary/$DATESTAMP/ocarina.files.ls"
ELAN_OK_FLAG="$ELAN_DIR/staging/summary/$DATESTAMP/elan.ok.flag"
OCARINA_OK_FLAG="$ELAN_DIR/staging/summary/$DATESTAMP/ocarina.ok.flag"

if [ ! -f "$ELAN_OK_FLAG" ]; then
    # If a log already exists, then the pipeline needs to be resumed
    RESUME_FLAG=""
    if [ -f "nf.elan.$DATESTAMP.log" ]; then
        RESUME_FLAG="-resume"
        MSG='{"text":"*COG-UK inbound pipeline* Using -resume to re-raise Elan without trashing everything. Delete today'\''s log to force a full restart."}'
        curl -X POST -H 'Content-type: application/json' --data "$MSG" $SLACK_MGMT_HOOK
    fi
    /usr/bin/flock -w 1 /dev/shm/.sam_elan -c "$NEXTFLOW_BIN run elan.nf -c $ELAN_CONFIG --dump $PRE_ELAN_DIR/latest.tsv --publish $ELAN_DIR --schemegit /cephfs/covid/software/sam/artic-ncov2019 --datestamp $DATESTAMP $RESUME_FLAG > nf.elan.$DATESTAMP.log 2>&1;"
    ret=$?
    mv .nextflow.log elan.nextflow.log

    if [ $ret -ne 0 ]; then
        lines=`tail -n 25 nf.elan.$DATESTAMP.log`
    else
        lines=`awk -vRS= 'END{print}' nf.elan.$DATESTAMP.log`
    fi

    MSG='{"text":"*COG-UK inbound pipeline finished...*
...with exit status '"$ret"'
'"\`\`\`${lines}\`\`\`"'
_Have a nice day!_"}'
    curl -X POST -H 'Content-type: application/json' --data "$MSG" $SLACK_MGMT_HOOK

    if [ $ret -ne 0 ]; then
        $ELAN_SOFTWARE_DIR/bin/control/handle-elan.sh $DATESTAMP
        exit $ret # get out of here before we loop ourselves into infinity
    else
        touch $ELAN_OK_FLAG
    fi
else
    MSG='{"text":"*COG-UK inbound pipeline* Cowardly skipping Elan as the OK flag already exists for today"}'
    curl -X POST -H 'Content-type: application/json' --data "$MSG" $SLACK_MGMT_HOOK
fi

# If the OCARINA_FILE has still not been written at this point, it means Elan ran but today's pipeline is empty - abort early but successfully, dont send a tael
if [ ! -f "$OCARINA_FILE" ]; then
    curl -X POST -H 'Content-type: application/json' --data '{"text":"\n*COG-UK inbound pipeline empty*\nNo new valid files today, try again tomorrow."}' $SLACK_REAL_HOOK
    exit 0
fi

if [ ! -f "$OCARINA_OK_FLAG" ]; then
    $NEXTFLOW_BIN run ocarina.nf -c $ELAN_CONFIG --manifest $OCARINA_FILE > nf.ocarina.$DATESTAMP.log 2>&1;
    ret=$?
    lines=`awk -vRS= 'END{print}' nf.ocarina.$DATESTAMP.log`
    MSG='{"text":"*COG-UK QC pipeline finished...*
...with exit status '"$ret"'
'"\`\`\`${lines}\`\`\`"'"
}'
    curl -X POST -H 'Content-type: application/json' --data "$MSG" $SLACK_MGMT_HOOK
    cat elan.nextflow.log .nextflow.log > inbound.nextflow.log

    if [ $ret -ne 0 ]; then
        MSG='{"text":"<!channel> *COG-UK inbound pipeline failed (Ocarina)*"}'
        curl -X POST -H 'Content-type: application/json' --data "$MSG" $SLACK_MGMT_HOOK
        exit $ret
    else
        touch $OCARINA_OK_FLAG
    fi
else
    MSG='{"text":"*COG-UK inbound pipeline* Cowardly skipping Ocarina as the OK flag already exists for today"}'
    curl -X POST -H 'Content-type: application/json' --data "$MSG" $SLACK_MGMT_HOOK
fi

bash $ELAN_SOFTWARE_DIR/bin/control/cog-publish.sh $DATESTAMP > $ELAN_DIR/staging/summary/$DATESTAMP/publish.log
ret=$?
MSG='{"text":"*COG-UK publishing pipeline finished...*
...with exit status '"$ret"'"}'
curl -X POST -H 'Content-type: application/json' --data "$MSG" $SLACK_MGMT_HOOK
if [ $ret -ne 0 ]; then
    MSG='{"text":"<!channel> *COG-UK inbound pipeline failed...*"}'
    curl -X POST -H 'Content-type: application/json' --data "$MSG" $SLACK_MGMT_HOOK
    exit $ret
fi

mv inbound.nextflow.log $ELAN_DIR/staging/summary/$DATESTAMP/nf.elan.$DATESTAMP.log

# Scream into the COGUK/ether
eval "$(conda shell.bash hook)"
conda activate sam-ipc
python $ELAN_SOFTWARE_DIR/bin/ipc/mqtt-message.py -t 'COGUK/infrastructure/pipelines/elan/status' --host $MQTT_HOST --attr status finished --attr date $DATESTAMP
