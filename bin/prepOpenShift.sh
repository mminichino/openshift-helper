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

which openshift-install 2>&1 >/dev/null
if [ $? -ne 0 ]; then
   echo  "openshift-install not found"
   exit 1
fi

which ansible-helper.py 2>&1 >/dev/null
if [ $? -ne 0 ]; then
   echo  "ansible-helper.py not found"
   exit 1
fi

while getopts "sce:d:t:w" opt
do
  case $opt in
    t)
      TEMPLATE=$OPTARG
      ;;
    c)
      [ ! -d ${CFGDIR} ] && mkdir ${CFGDIR}
      openshift-install create install-config --dir=${CFGDIR}
      cp ${CFGDIR}/install-config.yaml ${HOME}/${TEMPLATE}
      exit
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
      echo -n "Wipe install directory? [y/n]: "
      read ANSWER
      if [ "$ANSWER" == "y" ]; then
        rm -rvf ${CFGDIR}/*
      fi
      exit
      ;;
    \?)
      exit 1
      ;;
  esac
done

if [ -z "$HELPER_PATH" ]; then
  export HELPER_PATH=$PKGROOT/playbooks
else
  export HELPER_PATH=$HELPER_PATH:$PKGROOT/playbooks
fi

if [ "$STEP" -eq 1 ]
then
  echo -n "Copy install template? [y/n]: "
  read ANSWER
  if [ "$ANSWER" = "y" ]; then
     RUNSTEP=1
  else
     RUNSTEP=0
  fi
fi

if [ "$RUNSTEP" -eq 1 ]; then
  if [ ! -f ${HOME}/${TEMPLATE} ]; then
    echo "Can not find template file ${TEMPLATE}"
    exit 1
  fi
  echo -n "Copying install config to install directory ... "
  cp ${HOME}/${TEMPLATE} ${CFGDIR}/install-config.yaml
  if [ $? -ne 0 ]; then
    echo "Could not copy install config file."
    exit 1
  fi
  echo "Done."
fi

if [ "$STEP" -eq 1 ]
then
  echo -n "Generate Terraform variables file? [y/n]: "
  read ANSWER
  if [ "$ANSWER" = "y" ]; then
     RUNSTEP=1
  else
     RUNSTEP=0
  fi
fi

if [ "$RUNSTEP" -eq 1 ]; then
  $SCRIPTDIR/tfConfig.py --file ${CFGDIR}/install-config.yaml --dir ${PKGROOT}/terraform --install ${CFGDIR}
  if [ $? -ne 0 ]; then
    echo "Could not create Terraform variables file."
    exit 1
  fi
fi

if [ "$STEP" -eq 1 ]
then
  echo -n "Create manifests? [y/n]: "
  read ANSWER
  if [ "$ANSWER" = "y" ]; then
     RUNSTEP=1
  else
     RUNSTEP=0
  fi
fi

if [ "$RUNSTEP" -eq 1 ]; then
  echo "Creating manifests ..."
  openshift-install create manifests --dir=${CFGDIR}
  if [ $? -ne 0 ]; then
    echo "Could not create manifests."
    exit 1
  fi
  echo "Done."
fi

if [ "$STEP" -eq 1 ]
then
  echo -n "Remove IPI machine files? [y/n]: "
  read ANSWER
  if [ "$ANSWER" = "y" ]; then
     RUNSTEP=1
  else
     RUNSTEP=0
  fi
fi

if [ "$RUNSTEP" -eq 1 ]; then
  echo -n "Removing IPI machine files ..."
  rm -f ${CFGDIR}/openshift/99_openshift-cluster-api_master-machines-*.yaml ${CFGDIR}/openshift/99_openshift-cluster-api_worker-machineset-*.yaml
  if [ $? -ne 0 ]; then
    echo "Could not remove IPI machine files."
    exit 1
  fi
  echo "Done."
fi

if [ "$STEP" -eq 1 ]
then
  echo -n "Edit cluster-scheduler-02-config.yml? [y/n]: "
  read ANSWER
  if [ "$ANSWER" = "y" ]; then
     RUNSTEP=1
  else
     RUNSTEP=0
  fi
fi

if [ "$RUNSTEP" -eq 1 ]; then
  echo -n "Editing cluster-scheduler-02-config.yml ..."
  sed -i -e 's/mastersSchedulable: true/mastersSchedulable: False/' ${CFGDIR}/manifests/cluster-scheduler-02-config.yml
  if [ $? -ne 0 ]; then
    echo "Could not edit cluster-scheduler-02-config.yml."
    exit 1
  fi
  echo "Done."
fi

if [ "$STEP" -eq 1 ]
then
  echo -n "Creating ignition configs? [y/n]: "
  read ANSWER
  if [ "$ANSWER" = "y" ]; then
     RUNSTEP=1
  else
     RUNSTEP=0
  fi
fi

if [ "$RUNSTEP" -eq 1 ]; then
  echo "Creating ignition configs..."
  openshift-install create ignition-configs --dir=${CFGDIR}
  if [ $? -ne 0 ]; then
    echo "Could not create ignition configs."
    exit 1
  fi
  INFRA_ID=$(jq -r .infraID ${CFGDIR}/metadata.json)
  $SCRIPTDIR/tfConfig.py --set infra_id --value $INFRA_ID --dir ${PKGROOT}/terraform
  if [ $? -ne 0 ]; then
    echo "Could not update variables file with infrastructure ID."
    exit 1
  fi
  echo "Done."
fi

if [ "$STEP" -eq 1 ]
then
  echo -n "Convert ignition files to base64? [y/n]: "
  read ANSWER
  if [ "$ANSWER" = "y" ]; then
     RUNSTEP=1
  else
     RUNSTEP=0
  fi
fi

if [ "$RUNSTEP" -eq 1 ]; then
  echo -n "Converting ignition files to base64 ..."
  base64 -w0 ${CFGDIR}/master.ign > ${CFGDIR}/master.64
  base64 -w0 ${CFGDIR}/worker.ign > ${CFGDIR}/worker.64
  base64 -w0 ${CFGDIR}/bootstrap.ign > ${CFGDIR}/bootstrap.64
  echo "Done."
fi

if [ "$STEP" -eq 1 ]
then
  echo -n "Create VM templates? [y/n]: "
  read ANSWER
  if [ "$ANSWER" = "y" ]; then
     RUNSTEP=1
  else
     RUNSTEP=0
  fi
fi

if [ "$RUNSTEP" -eq 1 ]; then
  echo "Creating VM templates ... "
  VMWARE_HOST=$($SCRIPTDIR/tfConfig.py --get vsphere_server --dir ${PKGROOT}/terraform)
  VMWARE_USER=$($SCRIPTDIR/tfConfig.py --get vsphere_user --dir ${PKGROOT}/terraform)
  VMWARE_PASSWORD=$($SCRIPTDIR/tfConfig.py --get vsphere_password --dir ${PKGROOT}/terraform)
  VMWARE_FOLDER=$($SCRIPTDIR/tfConfig.py --get cluster_name --dir ${PKGROOT}/terraform)
  VMWARE_DATACENTER=$($SCRIPTDIR/tfConfig.py --get vsphere_datacenter --dir ${PKGROOT}/terraform)
  ansible-helper.py create-templates.yaml --vmware_host $VMWARE_HOST --vmware_user $VMWARE_USER --vsphere_password $VMWARE_PASSWORD --vmware_folder $VMWARE_FOLDER --vmware_dc $VMWARE_DATACENTER --dir $CFGDIR
fi

echo "Done."

##
