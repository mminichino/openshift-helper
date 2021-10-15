#!/bin/sh
#
DATE=$(date '+%H%M%S%m%d%y')
STEP=0
BASEDIR=$HOME
ENVNAME="oslab"
CFGDIR=${BASEDIR}/${ENVNAME}
RUNSTEP=1
SCRIPTDIR=$(cd $(dirname $0) && pwd)
PKGROOT=$(dirname $SCRIPTDIR)
TEMPLATE="install-config-template.yaml"

function wipe_install_dir {
echo -n "Wipe install directory? [y/n]: "
read ANSWER
if [ "$ANSWER" == "y" ]; then
  rm -rvf ${CFGDIR}/*
  rm -rvf ${CFGDIR}/.openshift_install*
fi
exit
}

function create_template {
[ ! -d ${CFGDIR} ] && mkdir ${CFGDIR}
openshift-install create install-config --dir=${CFGDIR}
cp ${CFGDIR}/install-config.yaml ${HOME}/${TEMPLATE}
exit
}

function destroy_cluster {
cd ${PKGROOT}/terraform
terraform destroy
cd ${PKGROOT}
exit
}

function ask_step_continue {
while true
do
  echo -n "$1 [y/n/q]: "
  read ANSWER
  if [ "$ANSWER" = "y" ]; then
     RUNSTEP=1
     return
  elif [ "$ANSWER" = "q" ]; then
     exit
  elif [ "$ANSWER" = "n" ]; then
     RUNSTEP=0
     return
  fi
done
}

function destroy_bootstrap {
ask_step_continue "Remove bootstrap node?"

if [ "$RUNSTEP" -eq 1 ]; then
  cd ${PKGROOT}/terraform
  terraform destroy -target vsphere_virtual_machine.bootstrap_node -auto-approve
  cd ${PKGROOT}
fi
exit
}

which openshift-install 2>&1 >/dev/null
if [ $? -ne 0 ]; then
   echo  "openshift-install not found"
   exit 1
fi

while getopts "sce:d:t:wrb" opt
do
  case $opt in
    t)
      TEMPLATE=$OPTARG
      ;;
    c)
      create_template
      ;;
    s)
      STEP=1
      ;;
    e)
      ENVNAME=$OPTARG
      ;;
    d)
      BASEDIR=$OPTARG
      CFGDIR=${BASEDIR}/${ENVNAME}
      ;;
    w)
      wipe_install_dir
      ;;
    r)
      destroy_cluster
      ;;
    b)
      destroy_bootstrap
      ;;
    \?)
      exit 1
      ;;
  esac
done

[ "$STEP" -eq 1 ] && ask_step_continue "Copy install template?"

if [ "$RUNSTEP" -eq 1 ]; then
  if [ ! -f ${HOME}/${TEMPLATE} ]; then
    echo "Can not find template file ${TEMPLATE}"
    exit 1
  fi
  echo -n "Copying install config to install directory ... "
  cp ${HOME}/${TEMPLATE} ${CFGDIR}/install-config.yaml && cp ${HOME}/${TEMPLATE} ${CFGDIR}/.install-config-copy.yaml
  if [ $? -ne 0 ]; then
    echo "Could not copy install config file."
    exit 1
  fi
  echo "Done."
fi

[ "$STEP" -eq 1 ] && ask_step_continue "Create manifests?"

if [ "$RUNSTEP" -eq 1 ]; then
  echo "Creating manifests ..."
  openshift-install create manifests --dir=${CFGDIR}
  if [ $? -ne 0 ]; then
    echo "Could not create manifests."
    exit 1
  fi
  echo "Done."
fi

[ "$STEP" -eq 1 ] && ask_step_continue "Remove IPI machine files?"

if [ "$RUNSTEP" -eq 1 ]; then
  echo -n "Removing IPI machine files ..."
  rm -f ${CFGDIR}/openshift/99_openshift-cluster-api_master-machines-*.yaml ${CFGDIR}/openshift/99_openshift-cluster-api_worker-machineset-*.yaml
  if [ $? -ne 0 ]; then
    echo "Could not remove IPI machine files."
    exit 1
  fi
  echo "Done."
fi

[ "$STEP" -eq 1 ] && ask_step_continue "Edit cluster-scheduler-02-config.yml?"

if [ "$RUNSTEP" -eq 1 ]; then
  echo -n "Editing cluster-scheduler-02-config.yml ..."
  sed -i -e 's/mastersSchedulable: true/mastersSchedulable: false/' ${CFGDIR}/manifests/cluster-scheduler-02-config.yml
  if [ $? -ne 0 ]; then
    echo "Could not edit cluster-scheduler-02-config.yml."
    exit 1
  fi
  echo "Done."
fi

[ "$STEP" -eq 1 ] && ask_step_continue "Creating ignition configs?"

if [ "$RUNSTEP" -eq 1 ]; then
  echo "Creating ignition configs..."
  openshift-install create ignition-configs --dir=${CFGDIR}
  if [ $? -ne 0 ]; then
    echo "Could not create ignition configs."
    exit 1
  fi
  echo "Done."
fi

[ "$STEP" -eq 1 ] && ask_step_continue "Generate Terraform variables file?"

if [ "$RUNSTEP" -eq 1 ]; then
  INFRA_ID=$(jq -r .infraID ${CFGDIR}/metadata.json)
  $SCRIPTDIR/tfConfig.py --file ${CFGDIR}/.install-config-copy.yaml --dir ${PKGROOT}/terraform --install ${CFGDIR} --id $INFRA_ID
  if [ $? -ne 0 ]; then
    echo "Could not create Terraform variables file."
    exit 1
  fi
fi

[ "$STEP" -eq 1 ] && ask_step_continue "Create cluster?"

if [ "$RUNSTEP" -eq 1 ]; then
  cd ${PKGROOT}/terraform
  terraform init
  terraform apply -auto-approve
  cd ${PKGROOT}
fi

[ "$STEP" -eq 1 ] && ask_step_continue "Monitor progress?"

if [ "$RUNSTEP" -eq 1 ]; then
  openshift-install --dir=${CFGDIR} wait-for bootstrap-complete --log-level=info
  if [ $? -ne 0 ]; then
    echo "Could not create cluster."
    exit 1
  fi
fi

[ "$STEP" -eq 0 ] && sleep 5
export KUBECONFIG=${CFGDIR}/auth/kubeconfig

[ "$STEP" -eq 1 ] && ask_step_continue "Approve CSRs?"

if [ "$RUNSTEP" -eq 1 ]; then
  CONTINUE=1
  SLEEP_COUNT=0
  NUM_WORKERS=$($SCRIPTDIR/tfConfig.py --get worker_count --dir ${PKGROOT}/terraform)
  while [ "$CONTINUE" -eq 1 ]; do
    CONTINUE=0
    pendingCount=$(oc get csr | grep "Pending" | wc -l)
    if [ "$pendingCount" -gt 0 ]; then
       oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs --no-run-if-empty oc adm certificate approve
    fi
    actualWorkerCount=$(oc get nodes --no-headers -o=custom-columns=NAME:.metadata.name | grep worker | wc -l)
    if [ "$actualWorkerCount" -ne "$NUM_WORKERS" ]; then
       CONTINUE=1
    fi
    for node in $(oc get nodes --no-headers -o=custom-columns=NAME:.metadata.name); do
    	nodeStatus=$(oc get --raw /api/v1/nodes/${node}/proxy/healthz 2>&1)
    	nodeStatus=$(echo $nodeStatus | sed -e '/^$/d')
    	if [ "$nodeStatus" != "ok" ]; then
    	   CONTINUE=1
    	fi
    done
    if [ "$CONTINUE" -eq 0 ]; then
       break
    fi
    if [ "$SLEEP_COUNT" -ge 120 ]; then
       echo "Timeout waiting for bootstrap to complete."
       exit 1
    fi
    sleep 30
    SLEEP_COUNT=$((SLEEP_COUNT + 1))
  done
echo "Done."
fi

if [ "$STEP" -eq 0 ]; then
  oc get nodes
fi

##
