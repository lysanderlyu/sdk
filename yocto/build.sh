#!/bin/bash

set -e

# 1. Configure build environment
export PROJ_ROOT=$(realpath ${PWD})
export OUTPUT_ROOT=${PROJ_ROOT}/output
export LOG_DIR=${OUTPUT_ROOT}/log
export TOPDIR=${PROJ_ROOT}
# export TEMPLATECONF=$PROJ_ROOT/src/meta-rb-s715/conf/templates/default
export TEMPLATECONF=$PROJ_ROOT/src/meta-rity/meta/conf/templates/default/

export FINAL_DISTRO="rity-demo-image"

# The variables below only take affect once after the build created
export FINAL_MACHINE="genio-720-evk"
export NUMS_TASK="8"
export NUMS_THREAD_PERTASK="10"
##################################################################

mkdir -p ${LOG_DIR}

# 2. enter the yocto environment
# Here pass an empty string or specific path to prevent it from consuming script arguments
source src/poky/oe-init-build-env ${PROJ_ROOT}/build > /dev/null
export BUILD_DIR=$(realpath ${PWD})


LOCAL_CONF="${BUILD_DIR}/conf/local.conf"

# Edit the config (Recommand to run the first time or you changes the MTK_CUSTOM_LOCAL_CONF)
do_local_conf ()
{
    # The MACHINE may be 1. enio-720-evk, 2.genio-720-evk-norboot-ufs
    tee >> "${LOCAL_CONF}" << EOF

# ---- Realbom Custom ----
DL_DIR = "${TOPDIR}/downloads"
SSTATE_DIR = "${TOPDIR}/sstate-cache"
MACHINE= "${FINAL_MACHINE}"
BB_NUMBER_THREADS = "${NUMS_TASK}"
PARALLEL_MAKE = "-j${NUMS_THREAD_PERTASK}"

EOF
}

# Build the config and extract before building
prepare_build () {
    # Append the Realbom Custom config to the LOCAL_CONF
    if ! grep -q "Realbom Custom" ${LOCAL_CONF}; then
        echo "This is the first time run, setting the custom config to ${LOCAL_CONF}"
        do_local_conf
    fi

    # Check the git2 dir exist on downloads dir or not
    if [ ! -e "${TOPDIR}/downloads/git2" ]; then
        echo "Extracting the downloaded git2 tarball under downloads dir, this may take a long time"
        if [ -e "${TOPDIR}/downloads/git2.tar.gz" ]; then
            tar xf "${TOPDIR}/downloads/git2.tar.gz" -C "${TOPDIR}/downloads"
        fi
    fi

}

# build the u-boot only
build_uboot ()
{
    prepare_build
    echo "Cleaning uboot building"
    bitbake -c cleanall u-boot
    echo "Starting Building uboot"
    bitbake u-boot -vv | tee ${LOG_DIR}/uboot.log
    echo "Log saved on ${LOG_DIR}/uboot.log"
    ln -sf ${BUILD_DIR}/tmp/deploy/* ${TOPDIR}/output/
}

# build the kernel only
build_kernel ()
{
    prepare_build
    echo "Cleaning kernel building"
    bitbake -c cleanall linux-mtk
    echo "Starting building kernel"
    bitbake linux-mtk -vv | tee ${LOG_DIR}/kernel.log
    echo "Log saved on ${LOG_DIR}/kernel.log"
    ln -sf ${BUILD_DIR}/tmp/deploy/* ${TOPDIR}/output/
}

# build the whole image
build_all ()
{
    prepare_build
    echo "Starting building all"
    bitbake ${FINAL_DISTRO}
    ln -sf ${BUILD_DIR}/tmp/deploy/* ${TOPDIR}/output/
    ln -sf ${BUILD_DIR}/tmp/work ${TOPDIR}/output/
}

# Building the rootfs
build_rootfs ()
{
    prepare_build
    echo "Building rootfs"
    ln -sf ${BUILD_DIR}/tmp/deploy/* ${TOPDIR}/output/
}

# pack the image
build_image ()
{
    prepare_build
    echo "Packing image"
    ln -sf ${BUILD_DIR}/tmp/deploy/* ${TOPDIR}/output/
}

# Run the bitbake-layers
build_bitbake_layers_command ()
{
    if [ $# -eq 0 ]; then
        echo "Usage: build.sh -l <command>"
        return 1
    fi
    bitbake-layers $@
    exit 0
}

# Run the custom bitbake command
build_bitbake_command ()
{
    if [ $# -eq 0 ]; then
        echo "Usage: build.sh -b <command>"
        return 1
    fi
    bitbake $@
    exit 0
}

# Show the finale environment for a package
build_environments ()
{
    if [ $# -eq 0 ]; then
        echo "Usage: build.sh -e <package>"
        return 1
    fi
    bitbake -e $1 > ${TOPDIR}/${1}.bb
}

# Show the append's info for a package
build_appends ()
{
    if [ $# -eq 0 ]; then
        echo "Usage: build.sh -A <package>"
        return 1
    fi
    bitbake show-appends $@
}

# Show the finale environment for a package
build_dependency ()
{
    if [ $# -eq 0 ]; then
        echo "Usage: build.sh -g <package>"
        return 1
    fi
    
    # # Check if dot command exists
    # if ! command -v dot &> /dev/null
    # then
    #     echo "Error: dot could not be found. Please install graphviz."
    #     return 1
    # fi
    
    bitbake -g $1
    PNG_FILENAME=${1}_task.png
    PN_FILENAME=${1}_builtlist
    # echo "Generating $PNG_FILENAME on $TOPDIR, this may take some time"
    # dot -Tpng $BUILDDIR/task-depends.dot -o $TOPDIR/$PNG_FILENAME
    echo "Dependency graph $TOPDIR/$PNG_FILENAME Generate success"
    cp $BUILDDIR/pn-buildlist $TOPDIR/$PN_FILENAME
    echo "Dependency build list of $1 generated on $TOPDIR/$PN_FILENAME"
}

# help info
usage() {
    echo "Usage:"
    echo "  $0 [options]"
    echo ""
    echo "Options:"
    echo "  -c    make REALBOM_CUSTOM_LOCAL_CONF effects agains"
    echo "  -u    build u-boot"
    echo "  -k    build kernel"
    echo "  -r    build rootfs"
    echo "  -a    build all"
    echo "  -A    showing the appends info"
    echo "  -e    showing the package environment info"
    echo "  -i    pack image"
    echo "  -b    run bitbake full named command"
    echo "  -l    run bitbake-layers full named command
    echo "  -g    generate packages dependency graph"
    echo "  -h    help"
    echo ""
    echo "Examples:"
    echo "  $0 -a         # build all for edp (default)"
    echo "  $0 -k         # build kernel"
    echo "  $0 -r         # build rootfs"
    echo "  $0 -u         # build u-boot"
    echo "  $0 -s show-layers         # show all packages"
    exit 1
}


# ===== main build =====
if [ $# -eq 0 ]; then
    usage
fi

while getopts "cukrabhielgA" opt; do
    case "$opt" in
        c) do_local_conf ;;
        u) build_uboot ;;
        k) build_kernel ;;
        r) build_rootfs ;;
        i) build_image ;;
        a) build_all ;;
        A) build_appends "$2" ;;
        e) build_environments "$2" ;;
        b) build_bitbake_command "${@:2}" ;;
        l) build_bitbake_layers_command "${@:2}" ;;
        g) build_dependency "${@:2}" ;;
        h|*) usage ;;
    esac
done
