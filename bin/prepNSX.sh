#!/bin/sh
#
BASEDIR=$HOME
ENVNAME="oslab"
CFGDIR=${BASEDIR}/${ENVNAME}
SCRIPTDIR=$(cd $(dirname $0) && pwd)
PKGROOT=$(dirname $SCRIPTDIR)
TEMPLATE="install-config-template.yaml"

while getopts "ce:d:t:" opt
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
    e)
      ENVNAME=$OPTARG
      ;;
    d)
      BASEDIR=$OPTARG
      CFGDIR=${BASEDIR}/${ENVNAME}
      ;;
    \?)
      exit 1
      ;;
  esac
done

$SCRIPTDIR/tfConfig.py --nsx ${HOME}/${TEMPLATE} --dir ${PKGROOT}/nsxt

cd ${PKGROOT}/nsxt

terraform init
terraform apply -auto-approve

cd ${PKGROOT}
