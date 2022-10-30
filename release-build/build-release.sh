#!/bin/bash

SCRIPT="$(readlink --canonicalize-existing "$0")"
SCRIPTPATH="$(dirname "${SCRIPT}")"
SCRIPTNAME=${SCRIPT##*/}

usage () {
    echo "Usage: ${SCRIPTNAME} [-noreg] [-repack] [-tag TAG] MODEL VERSION [EXTRA]"
    echo
    echo "  -noreg    skip regression testing"
    echo "  -repack   don't copy new stuff, redo cor and mcs, make new 7z"
    echo "  -tag TAG  TAG defaults to the 6 first characters of the branch, use"
    echo "            this for setting something like 'release-0.95'"
    echo "  MODEL     one of mega65r3, mega65r2, nexys4ddr-widget"
    echo "  VERSION   version string to put before the hash into the core version"
    echo "  EXTRA     file to put into the mega65r3 cor for fdisk population"
    echo "            (default is everything in sdcard-files)"
    echo
    echo "Example: ${SCRIPTNAME} mega65r3 'Experimental Build'"
    echo
    if [[ "x$1" != "x" ]]; then
        echo $1
        echo
    fi
    exit 1
}

rom_first () {
    for file in $@; do
        if [[ ${file##*/} = "MEGA65.ROM" ]]; then
            echo ${file}
        fi
    done
    for file in $@; do
        if [[ ${file##*/} = "FREEZER.M65" ]]; then
            echo ${file}
        fi
    done
    for file in $@; do
        if [[ ${file##*/} != "MEGA65.ROM" && ${file##*/} != "FREEZER.M65" ]]; then
            echo ${file}
        fi
    done
}

TAG="NULL"
REPACK=0
NOREG=0
while [[ $# -gt 2 && $1 =~ ^-.+ ]]; do
    if [[ $1 == "-noreg" ]]; then
        NOREG=1
    elif [[ $1 == "-repack" ]]; then
        NOREG=1
        REPACK=1
    elif [[ $1 == "-tag" ]]; then
        shift
        TAG=$1
    else
        usage "unknown option $1"
    fi
    shift
done

if [[ $# -lt 2 ]]; then
    usage
fi

MODEL=$1
VERSION=$2
shift 2
EXTRA_FILES=""
RM_HASROM=""
ROM_FILE=""
for file in $@; do
    if [[ ! -r ${file} ]]; then
        usage "extra file is unreadable: ${file}"
    elif [[ ${file##*/} = "MEGA65.ROM" ]]; then
        ROM_FILE=${file}
    else
        EXTRA_FILES="${EXTRA_FILES} ${file}"
    fi
done

# determine branch
if [[ ${TAG} == "NULL" ]]; then
    BRANCH=`git rev-parse --abbrev-ref HEAD`
    BRANCH=${BRANCH:0:6}
else
    BRANCH=${TAG}
fi

if [[ ${MODEL} = "mega65r3" ]]; then
    RM_TARGET="MEGA65R3 boards -- DevKit, MEGA65 R3 and R3a (Artix A7 200T FPGA)"
elif [[ ${MODEL} = "mega65r2" ]]; then
    RM_TARGET="MEGA65R2 boards -- Limited Testkit (Artix A7 100T FPGA)"
elif [[ ${MODEL} = "nexys4ddr-widget" ]]; then
    RM_TARGET="Nexys4DDR boards -- Nexys4DDR, NexysA7 (Artix A7 100T FPGA)"
else
    usage "unknown model ${MODEL}"
fi

PKGBASE=${SCRIPTPATH}/pkg
PKGPATH=${PKGBASE}/${MODEL}-${BRANCH}
REPOPATH=${SCRIPTPATH%/*}

if [[ ${REPACK} -eq 0 ]]; then
    echo "Cleaning ${PKGPATH}"
    echo
    rm -rvf ${PKGPATH}
else
    if [[ -e ${PKGPATH}/sdcard-files/MEGA65.ROM ]]; then
        ROM_FILE=${PKGPATH}/sdcard-files/MEGA65.ROM
    fi
fi

if [[ ${ROM_FILE} != "" ]]; then
    RM_HASROM="
This package also contains a ROM, which is included in the COR for automatic population
and can also be found in \`sdcard-files\`.
"
fi

for dir in ${PKGPATH}/log ${PKGPATH}/sdcard-files ${PKGPATH}/extra; do
    if [[ ! -d ${dir} ]]; then
        mkdir -p ${dir}
    fi
done

# put text files into package path
echo "Creating info files from templates"
for txtfile in README.md Changelog.md; do
    echo ".. ${txtfile}"
    ( RM_TARGET="${RM_TARGET}" RM_HASROM="${RM_HASROM}" envsubst < ${SCRIPTPATH}/${txtfile} > ${PKGPATH}/${txtfile} )
done

# we always pack the latest bitstream
BITPATH=$( ls -1 --sort time ${REPOPATH}/bin/${MODEL}*.bit | head -1 )
BITNAME=${BITPATH##*/}
BITBASE=${BITNAME%.bit}
HASH=${BITBASE##*-}

echo
echo "Bitstream found: ${BITNAME}"
echo

if [[ ${REPACK} -eq 0 ]]; then
    echo "Copying build files"
    echo
    cp ${REPOPATH}/bin/HICKUP.M65 ${PKGPATH}/extra/
    if [[ ${ROM_FILE} != "" ]]; then
        cp ${ROM_FILE} ${PKGPATH}/sdcard-files/
    fi
    cp ${REPOPATH}/sdcard-files/* ${PKGPATH}/sdcard-files/
    if [[ ${MODEL} = "mega65r3" ]]; then
        cp ${REPOPATH}/src/utilities/jtagflash.prg ${PKGPATH}/extra/spiflash.prg
    fi
    cp ${BITPATH} ${PKGPATH}/
    cp ${BITPATH%.bit}.log ${PKGPATH}/log/
    cp ${BITPATH%.bit}.timing.txt ${PKGPATH}/log/
    VIOLATIONS=$( grep -c VIOL ${BITPATH%.bit}.timing.txt )
    if [[ $VIOLATIONS -gt 0 ]]; then
        touch ${PKGPATH}/WARNING_${VIOLATIONS}_TIMING_VIOLATIONS
    fi
fi

echo "Building COR/MCS"
echo
if [[ ${MODEL} == "nexys4ddr-widget" ]]; then
    bit2core nexys4ddrwidget ${PKGPATH}/${BITNAME} MEGA65 "${VERSION} ${HASH}" ${PKGPATH}/${BITBASE}.cor
elif [[ ${MODEL} == "mega65r2" ]]; then
    bit2core mega65r2 ${PKGPATH}/${BITNAME} MEGA65 "${VERSION} ${HASH}" ${PKGPATH}/${BITBASE}.cor
else
    bit2core ${MODEL} ${PKGPATH}/${BITNAME} MEGA65 "${VERSION} ${HASH}" ${PKGPATH}/${BITBASE}.cor $( rom_first ${PKGPATH}/sdcard-files/* ) ${EXTRA_FILES}
fi
bit2mcs ${PKGPATH}/${BITBASE}.cor ${PKGPATH}/${BITBASE}.mcs 0

# do regression tests
echo
if [[ ${NOREG} -eq 1 ]]; then
    echo "Skipping regression tests"
    if [[ ${REPACK} -eq 0 ]]; then
        touch ${PKGPATH}/WARNING_NO_TESTS_COULD_BE_EXECUTED
    fi
else
    echo "Starting regression tests"
    ${REPOPATH}/../mega65-tools/src/tests/regression-test.sh ${BITPATH} ${PKGPATH}/log/
    if [[ $? -ne 0 ]]; then
        touch ${PKGPATH}/WARNING_TESTS_HAVE_FAILED_SEE_LOGS
    fi
    echo "done"
fi
echo

ARCFILE=${PKGBASE}/${MODEL}-${BRANCH}-${HASH}.7z
if [[ -e ${ARCFILE} ]]; then
    rm -f ${ARCFILE}
fi

# 7z will only put the relative paths between ARCFILE and PKGPATH inside the archive. smart!
7z a ${ARCFILE} ${PKGPATH}
