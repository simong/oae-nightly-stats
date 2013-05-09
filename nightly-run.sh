#!/bin/bash
# This bash script holds the commands to start
# a new dataload and run the standard tsung suite.

# Configuration

# Whether or not the app and db servers should be reset?
START_CLEAN_APP=true
START_CLEAN_DB=true
START_CLEAN_WEB=true
START_CLEAN_SEARCH=true

LOG_DIR=/var/www/`date +"%Y/%m/%d/%H/%M"`
TEST_LABEL=$1

LOAD_NR_OF_BATCHES=1
LOAD_NR_OF_CONCURRENT_BATCHES=1
LOAD_NR_OF_USERS=1000
LOAD_NR_OF_GROUPS=2000
LOAD_NR_OF_CONTENT=5000

# Admin host
ADMIN_HOST='admin.oae-performance.oaeproject.org'

# Tenant host
TENANT_ALIAS='oae'
TENANT_NAME='Open Academic Environment'
TENANT_HOST="${TENANT_ALIAS}.oae-performance.oaeproject.org"

# Circonus configuration
CIRCONUS_AUTH_TOKEN="46c8c856-5912-4da2-c2b7-a9612d3ba949"
CIRCONUS_APP_NAME="oae-nightly-run"

PUPPET_REMOTE='sakaiproject'
PUPPET_BRANCH='master'

# How long (in seconds) to sleep to let activities generate before wiping out pending activities
ACTIVITY_SLEEP=120

# Increase the number of open files we can have.
prctl -t basic -n process.max-file-descriptor -v 32678 $$

# Log everything
mkdir -p ${LOG_DIR}
exec &> "${LOG_DIR}/nightly.txt"

## Refresh the puppet configuration on the puppetmaster
# Delete and re-clone puppet repository
ssh -t $1@$2 << EOF
    rm -rf puppet-hilary;
    git clone http://github.com/${PUPPET_REMOTE}/puppet-hilary;
    cd puppet-hilary;
    git checkout ${PUPPET_BRANCH};
    bin/pull.sh;
EOF

####################
# Helper functions #
####################

function destroyEnvironment {
    # Copy all the server logs and zip them up
    mkdir "${LOG_DIR}/serverlogs"
    scp -r root@$sakaigerperformance_syslog:/var/log/rsyslog "${LOG_DIR}/serverlogs"
    tar -cvzf "${LOG_DIR}/serverlogs.tar.gz" "${LOG_DIR}/serverlogs"
    rm -rf "${LOG_DIR}/serverlogs"

    # Destroy all the machines
    node slapchop.js --environment env-performance --datacenter eu-ams-1 --account sakaiger --destroy y -f ! puppet destroy
}
trap destroyEnvironment EXIT

# Create all the nodes.
# In case the nodes were already running, this won't do much.
cd /root/slapchop
node slapchop.js --environment env-performance --datacenter eu-ams-1 --account sakaiger --create y bootstrap

# Get all the nodes as environment variables.
# ex: this makes app0 available with $sakaigerperformance_app0
node slapchop.js --environment env-performance --datacenter eu-ams-1 --account sakaiger create-provision-script | tail -n +2 foo | head -n -1 | bash

# Create the provisioning script.
# Add the wait commando to the provision script.
# This means we'll only return when all the SSH commands have run.
node slapchop.js --environment env-performance --datacenter eu-ams-1 --account sakaiger create-provision-script | tail -n +2 foo | head -n -1 > /tmp/provision-script.sh
echo "\nwait" >> /tmp/provision-script.sh

# By executing it, we'll setup the puppet agent and mcollective on each node.
# In case the nodes were already running, this will just execute some apt-get update statements which is pretty harmless
chmod u+x /tmp/provision-script.sh
/tmp/provision-script.sh

# All nodes have puppet and MCO, reboot everything except for puppetmaster.
# SlapChop will take care of waiting till every node is back up.
node slapchop.js --environment env-performance --datacenter eu-ams-1 --account sakaiger -f ! puppet reboot

# Sleep 30 seconds so that each node has the time to make itself known to the puppetmaster
# and the puppetmaster can sign the certificates.
sleep 30

# Each node will try to pull down the latest catalog.
# Wait till all nodes have it.
nodes_applying=1
attempts=0
while [ $nodes_applying -gt 0 ] ; do
    nodes_applying=$(mco puppet status | grep 'Currently applying a catalog;' | wc -l)

    # Don't poll forever..
    attempts=$(($attempts + 1))
    if [ $attempts -eq 60 ] ; then
        echo "Some nodes took longer then 10 minutes to apply their catalog."
        echo "That doesn't seem right. Aborting performance run."

        # Do another puppet status to show which ones.
        mco puppet status
        exit 1
    fi

    # Sleep for 10 seconds before polling again.
    sleep 10
done

# If we get to this point, that means all nodes have installed all their services.
# Restart the services in the right order and we should have an up-and-running environment.
mco service -W '::oaeservice::cassandra' cassandra restart
mco service -W '::oaeservice::redis' redis restart
mco service -W '::oaeservice::elasticsearch' elasticsearch restart
mco service -W '::oaeservice::rabbitmq-server' rabbitmq-server restart

# Give the dependencies some time to bootstrap themselves before connecting.
sleep 10
mco service -W '::oaeservice::hilary' hilary restart

# Give the Hilary servers some time to bootstrap themselves before running nginx.
# Nginx seems to start faster if it can immediately connect to an upstream server
sleep 10
mco service -W '::oaeservice::nginx' hilary restart



# Do a fake request to nginx to poke the balancers
curl -e "/" http://${ADMIN_HOST}

# Flush redis.
ssh -t root@$sakaigerperformance_cache0 redis-cli flushall

# Get an admin session to play with.
ADMIN_COOKIE=$(curl -s -e "/" --cookie-jar - -d"username=administrator" -d"password=administrator" http://${ADMIN_HOST}/api/auth/login | grep connect.sid | cut -f 7)

# Create a tenant.
# In case we start from a snapshot, this will fail.
curl -e "/" --cookie connect.sid=${ADMIN_COOKIE} -d"alias=${TENANT_ALIAS}" -d"name=${TENANT_NAME}" -d"host=${TENANT_HOST}" http://${ADMIN_HOST}/api/tenant/create

# Turn reCaptcha checking off.
curl -e "/" --cookie connect.sid=${ADMIN_COOKIE} -d"oae-principals/recaptcha/enabled=false" http://${ADMIN_HOST}/api/config

# Configure the file storage.
curl -e "/" --cookie connect.sid=${ADMIN_COOKIE} \
    -d"oae-content/storage/backend=local" \
    -d"oae-content/storage/local-dir=/shared/files" http://${ADMIN_HOST}/api/config



# Model loader
cd ~/OAE-model-loader
rm -rf scripts/*
git pull origin Hilary
npm update



# Generate data.
START=`date +%s`
echo "Data generation started at: " `date`
node generate.js -b ${LOAD_NR_OF_BATCHES} -t ${TENANT_ALIAS} -u ${LOAD_NR_OF_USERS} -g ${LOAD_NR_OF_GROUPS} -c ${LOAD_NR_OF_CONTENT} >> ${LOG_DIR}/generate.txt 2>&1
tar cvzf scripts.tar.gz scripts
mv scripts.tar.gz ${LOG_DIR}
END=`date +%s`
GENERATION_DURATION=$(($END - $START));
curl -H "X-Circonus-Auth-Token: ${CIRCONUS_AUTH_TOKEN}" -H "X-Circonus-App-Name: ${CIRCONUS_APP_NAME}" -d"annotations=[{\"title\": \"Data generation\", \"description\": \"Generating fake users, groups, content\", \"category\": \"nightly\", \"start\": ${START}, \"stop\": ${END} }]"  https://circonus.com/api/json/annotation
echo "Data generation ended at: " `date`



# Load it up
START=`date +%s`
echo "Load started at: " `date`
node loaddata.js -s 0 -b ${LOAD_NR_OF_BATCHES} -c ${LOAD_NR_OF_CONCURRENT_BATCHES} -h http://${TENANT_HOST} > ${LOG_DIR}/loaddata.txt 2>&1
END=`date +%s`
LOAD_DURATION=$(($END - $START));
LOAD_REQUESTS=$(grep 'Requests made:' ${LOG_DIR}/loaddata.txt | tail -n 1 | cut -f 3 -d " ");
curl -H "X-Circonus-Auth-Token: ${CIRCONUS_AUTH_TOKEN}" -H "X-Circonus-App-Name: ${CIRCONUS_APP_NAME}" -d"annotations=[{\"title\": \"Data load\", \"description\": \"Loading the generated data into the system.\", \"category\": \"nightly\", \"start\": ${START}, \"stop\": ${END} }]"  https://circonus.com/api/json/annotation
echo "Load ended at: " `date`


# Sleep a bit so that all files are closed.
sleep 30


# Generate a tsung suite
cd ~/node-oae-tsung
git pull
npm update
mkdir -p ${LOG_DIR}/tsung
node --stack_size=2048 main.js -a /root/oae-nightly-stats/answers.json -s /root/OAE-model-loader/scripts -b ${LOAD_NR_OF_BATCHES} -o ${LOG_DIR}/tsung -m ${TSUNG_MAX_USERS} >> ${LOG_DIR}/package.txt 2>&1


echo "Sleeping ${ACTIVITY_SLEEP} seconds before clearing activity cache"
sleep $ACTIVITY_SLEEP

# Clean out all pending activities before the performance test
ssh -t root@$sakaigerperformance_cache0 redis-cli flushall


# Capture some graphs.
ssh -n -f root@$sakaigerperformance_app0 ". ~/.profile && nohup sh -c /home/admin/flamegraphs.sh > /dev/null 2>&1 &"

# Run the tsung tests.
START=`date +%s`
echo "Starting tsung suite at" `date`
cd ${LOG_DIR}/tsung
tsung -f tsung.xml -l ${LOG_DIR}/tsung start > ${LOG_DIR}/tsung/run.txt 2>&1
# Tsung appends a YYYMMDD-HHmm to the specified log dir,
# grep it out so we can run the stats
TSUNG_LOG_DIR=$(grep -o '/var/www[^"]*' $LOG_DIR/tsung/run.txt)
cd $TSUNG_LOG_DIR
touch "${TEST_LABEL}.label"
/opt/local/lib/tsung/bin/tsung_stats.pl
END=`date +%s`
curl -H "X-Circonus-Auth-Token: ${CIRCONUS_AUTH_TOKEN}" -H "X-Circonus-App-Name: ${CIRCONUS_APP_NAME}" -d"annotations=[{\"title\": \"Performance test\", \"description\": \"The tsung tests hitting the various endpoints.\", \"category\": \"nightly\", \"start\": ${START}, \"stop\": ${END} }]"  https://circonus.com/api/json/annotation
echo "Tsung suite ended at " `date`


# Copy over the graphs.
scp -r root@$sakaigerperformance_app0:/home/admin/graphs ${LOG_DIR}

# Generate some simple stats.
cd ~/oae-nightly-stats
node main.js -b ${LOAD_NR_OF_BATCHES} -u ${LOAD_NR_OF_USERS} -g ${LOAD_NR_OF_GROUPS} -c ${LOAD_NR_OF_CONTENT} --generation-duration ${GENERATION_DURATION} --dataload-requests ${LOAD_REQUESTS} --dataload-duration ${LOAD_DURATION} --tsung-report ${TSUNG_LOG_DIR}/report.html > ${LOG_DIR}/stats.html



