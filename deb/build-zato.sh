#!/bin/bash

function usage(){
    echo "$0 BRANCH_NAME ZATO_VERSION PYTHON_EXECUTABLE [PACKAGE_VERSION] [PROCESS]"
    echo ""
    echo "BRANCH_NAME: zatosource/zato branch name to build (e.g. master)"
    echo "ZATO_VERSION: zato version to build (e.g. 3.0.0)"
    echo "PYTHON_EXECUTABLE: Python executable to use (e.g. python, python2 or python3)"
    echo "PACKAGE_VERSION: (optional) package version to build. The acceptable values for package-version are:"
    echo "                 * \"\" (empty) or \"stable\", for stable versions."
    echo "                 * \"alpha\", \"beta\", \"pre\" or \"rc\" followed by one or more digits."
    echo "PROCESS: (optional) should be \"travis\" if run inside TravisCI"
}

if [[ "$1" == "-h" || "$1" == "--help" ]] ; then
    usage
    exit 0
fi

if [[ -z "$1" ]] ; then
    echo Argument 1 must be the branch name from zatosource/zato used to build the package.
    exit 1
fi

if [[ -z "$2" || -z "$(echo $2| grep -E '^[0-9]+\.[0-9]+\.[0-9]+')" ]] ; then
    echo Argument 2 must be the Zato version to build.
    exit 1
fi

if [[ -z "$3" || -z "$(echo $3| grep -E '^python[2,3]?\.?')" ]] ; then
    echo Argument 3 must be the Python executable to use e.g. python, python2 or python3.
    exit 1
fi

if [[ -n "$4" && -z "$(echo $4| grep -E '^(stable|alpha|beta|pre|rc)')" ]] ; then
    echo Argument 4 is the release level of the build. The value has to be empty or be one of: stable, alpha, beta, pre or rc.
    exit 1
fi

BRANCH_NAME=$1
ZATO_VERSION=$2
PY_BINARY=$3
[[ -n "$4" ]] && PACKAGE_VERSION_SUFFIX="_${4}"
TRAVIS_PROCESS_NAME=$5

if ! [ -x "$(command -v $PY_BINARY)" ]; then
  sudo apt-get install -y $PY_BINARY
fi

# Python 2 dependencies
PYTHON_DEPENDENCIES="python2.7, python-pip"
PACKAGE_VERSION="${PACKAGE_VERSION_SUFFIX}python27"
if [[ $(${PY_BINARY} -c 'import sys; print(sys.version_info[:][0])') -eq 3 ]]
then
    # Python 3 dependencies
    PACKAGE_VERSION="${PACKAGE_VERSION_SUFFIX}python3"
    PYTHON_DEPENDENCIES="python3, python3-pip"
fi

CURDIR="${BASH_SOURCE[0]}";RL="readlink";([[ `uname -s`=='Darwin' ]] || RL="$RL -f")
while([ -h "${CURDIR}" ]) do CURDIR=`$RL "${CURDIR}"`; done
N="/dev/null";pushd .>$N;cd `dirname ${CURDIR}`>$N;CURDIR=`pwd`;popd>$N

SOURCE_DIR=$CURDIR/package-base
ARCH=`dpkg --print-architecture`
RELEASE_NAME=`lsb_release -cs`

ZATO_ROOT_DIR=/opt/zato
ZATO_TARGET_DIR=$ZATO_ROOT_DIR/$ZATO_VERSION

if ! [ -x "$(command -v lsb_release)" ]; then
  sudo apt-get install -y lsb-release
fi

# Ubuntu and Debian require different versions of packages.
if command -v lsb_release > /dev/null; then
    release=$(lsb_release -c | cut -f2)
    if [[ "$release" == "precise" ]] || [[ "$release" == "wheezy" ]]; then
        LIBATLAS3BASE=libatlas3gf-base
        LIBBLAS3=libblas3gf
        LIBLAPACK3=liblapack3gf
        LIBUMFPACK_VERSION=5.4.0
        LIBEVENT_VERSION=2.0-5
    elif [[ "$release" == "xenial" ]]; then
        LIBATLAS3BASE=libatlas3-base
        LIBBLAS3=libblas3
        LIBLAPACK3=liblapack3
        LIBUMFPACK_VERSION=5.7.1
        LIBEVENT_VERSION=2.0-5
    elif [[ "$release" == "bionic" ]]; then
        LIBATLAS3BASE=libatlas3-base
        LIBBLAS3=libblas3
        LIBLAPACK3=liblapack3
        LIBUMFPACK_VERSION=5
        LIBEVENT_VERSION=2.1-6
    elif [[ "$release" == "stretch" ]]; then
        LIBATLAS3BASE=libatlas3-base
        LIBBLAS3=libblas3
        LIBLAPACK3=liblapack3
        LIBUMFPACK_VERSION=5
        LIBEVENT_VERSION=2.0-5
    else
        LIBATLAS3BASE=libatlas3gf-base
        LIBBLAS3=libblas3gf
        LIBLAPACK3=liblapack3gf
        LIBUMFPACK_VERSION=5.6.2
        LIBEVENT_VERSION=2.0-5
    fi

    # Add Debian-specific dependencies
    if [[ "$release" == "wheezy" ]]; then
        sudo apt-get install apt-transport-https python-software-properties
        sudo apt-add-repository 'deb http://ftp.is.debian.org/debian wheezy-backports main'
        sudo apt-get install --reinstall libffi5
    fi
fi

echo Building `lsb_release -is` DEB zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH-$RELEASE_NAME

function cleanup {
    sudo rm -rf $ZATO_TARGET_DIR
    sudo rm -rf $CURDIR/BUILDROOT
}

function checkout_zato {
    sudo mkdir -p $ZATO_TARGET_DIR
    sudo chown $USER $ZATO_TARGET_DIR

    git clone --depth 1 --no-single-branch https://github.com/zatosource/zato.git $ZATO_TARGET_DIR
    cd $ZATO_TARGET_DIR

    for branch in `git branch -a | grep remotes | grep -v HEAD | grep -v master `; do
      git branch --track ${branch#remotes/origin/} $branch
    done

    git checkout $BRANCH_NAME
}

function install_zato {

    cd $ZATO_TARGET_DIR/code
    sed -i -e 's|dateparser==0.5.1|dateparser==0.7.1|' requirements.txt
    if [[ $(${PY_BINARY} -c 'import sys; print(sys.version_info[:][1])') -eq 4 ]]; then
        sed -i -e 's|pg8000==1.13.1|pg8000==1.12.3|' _req_py3.txt
    fi
    ./install.sh -p ${PY_BINARY}

    find $ZATO_TARGET_DIR/. -name *.pyc -exec rm -f {} \;
    find $ZATO_TARGET_DIR/. ! -perm /004 -exec chmod 644 {} \;
    rm -f ./code/hotfixman.sh
    rm -rf ./code/hotfixes
    cd $CURDIR

}

function build_deb {

    mkdir $CURDIR/BUILDROOT
    mkdir $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH
    mkdir $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/opt
    mkdir $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH$ZATO_ROOT_DIR
    mkdir $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/etc
    mkdir $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/etc/bash_completion.d

    cd $CURDIR
    cp -r ../bash_completion/zato $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/etc/bash_completion.d/
    cp -r ../init_scripts/etc $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/
    cp -r ../init_scripts/lib $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/

    cp -r $ZATO_TARGET_DIR $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH$ZATO_TARGET_DIR
    cp -r $SOURCE_DIR/DEBIAN $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH
    cd $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH

    find . -path './DEBIAN' -prune -o -type f -exec md5sum {} + | sed -e 's/.\/opt/opt/g' > $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/DEBIAN/md5sums
    SIZE=`du -sk $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/opt |awk '{print $1}'`

    sed "s/Version: VER/Version: $ZATO_VERSION-$PACKAGE_VERSION/g" $SOURCE_DIR/DEBIAN/control | sed "s/Architecture: ARCH/Architecture: $ARCH/g" | sed "s/Installed-Size: SIZE/Installed-Size: $SIZE/g" > $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/DEBIAN/control
    sed -i "s/LIBATLAS3BASE/$LIBATLAS3BASE/g" $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/DEBIAN/control
    sed -i "s/LIBBLAS3/$LIBBLAS3/g" $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/DEBIAN/control
    sed -i "s/LIBLAPACK3/$LIBLAPACK3/g" $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/DEBIAN/control
    sed -i "s/LIBUMFPACK_VERSION/$LIBUMFPACK_VERSION/g" $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/DEBIAN/control
    sed -i "s/LIBEVENT_VERSION/$LIBEVENT_VERSION/g" $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/DEBIAN/control
    sed -i "s/RELEASE_NAME/$RELEASE_NAME/g" $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/DEBIAN/control
    sed -i "s/PYTHON_DEPENDENCIES/$PYTHON_DEPENDENCIES/g" $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/DEBIAN/control
    sed -i "s/ZATO_VERSION/$ZATO_VERSION/g" $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/DEBIAN/postinst
    sed -i "s/ZATO_VERSION/$ZATO_VERSION/g" $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/DEBIAN/postrm

    cat $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH/DEBIAN/control
    cd $CURDIR/BUILDROOT
    dpkg-deb --build zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH

    if [[ -n $TRAVIS_PROCESS_NAME && $TRAVIS_PROCESS_NAME == "travis" ]]; then
        [[ -d "/tmp/packages/$(lsb_release -c | cut -f2)/" ]] || mkdir -p "/tmp/packages/$(lsb_release -c | cut -f2)/"
        cp $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH.deb "/tmp/packages/$(lsb_release -c | cut -f2)/"
    fi

    mv $CURDIR/BUILDROOT/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH.deb $CURDIR/zato-$ZATO_VERSION-$PACKAGE_VERSION\_$ARCH-$RELEASE_NAME.deb
}

cleanup
checkout_zato
install_zato
build_deb
