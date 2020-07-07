#!/usr/bin/env bash

########################################################################
#
# This script aims to allow for easy to use and reproduceable benchmarks
# for the pyglasma3d_numba project.
#
# Out of the box this script will execute a comprehensive benchmark run
# that will include all available features. Advanced customization with
# command line arguments is also possible. Use:
# `$ ./run_benchmark.sh -h [--help]`
# for a list and descriptions of all required and optional arguments.
#
# The benchmark configuration and output logs will be saved to files.
# The timing results for the benchmark will be saved as json files.
#
# By default the benchmark will download the latest version of the
# source code from GitLab and will not use the repository it is part of.
# However, this defeats the purpose of reproduceability, as the hash of
# the used version is not saved. Therefore it is advised to specify an
# available git tag as the -s [--source] argument, which will then be
# downloaded and used for the benchmarks. Please check the help dialog
# for all available tags.
# Additionally it is also possible to supply the path to a local copy of
# the source archive with the -s [--source] argument. This archive has
# to be a .tar.gz archive, manually downloaded from GitLab, that matches
# any of the supported git tags. The checksum of the supplied archive
# will be calculated and compared to saved checksums in order to ensure
# that the source archive is unchanged.
#
# This benchmark script works with conda environments per default, if
# conda is installed. If conda cannot be found in PATH, then standard
# Python environments with the venv module are used.
# For the benchmark a fresh virtual environment will be created by
# default. However, it is possible to supply an existing venv with the
# -e [--env] argument (the string "create new" is reserved and must not
# be used as env name). Beware though, that this venv will be changed to
# ensure that all packages match the versions specified by the
# `pip_requirements.txt` or `conda-environment.yml` files of the
# source version in use.
# Please make sure that in this case the correct version of the Python
# interpreter is symlinked to the `python` command in the active venv.
# The -d [--device] cython requires Python >2.7.9,
# -d [--device] {cuda|numba} Python3, where the exact minor release will
# changed based on the source archive.
#
# If the benchmark fails and no output is saved to the specified output
# location, please make sure to check the specified working directory.
# It will contain any result files that have been generated until the
# benchmark failed. Use those files with caution, as they will be
# incomplete and not in a valid json format.
#
# Dependencies:
# #############
#
# - Python interpreter: for '--device numba|cuda': Version 3
#                       for '--device cython': Version 2
# - GNU 'time' command: https://www.gnu.org/software/time/
# - NVIDIA Driver and Cuda (via 'cudatoolkit'), if '--device cuda'
# - `virtualenv` Python package: https://virtualenv.pypa.io/en/latest/
#   if '--device cython' in Python mode and not providing '--env path',
#   used for creating virtual environments for Python2
# - GCC or equivalent C compiler: if '--device cython'
#
########################################################################


# error management
##################
# exit script on error
set -eE

# define cleanup function if bench run fails
bench_failed() {
    # if called manually, MUST be called after last benchmark function

    # set tag for marking, "FAILED" if called via trap, else use arg 1
    tag=${1:-"FAILED"}

    # rename WDIR to "WDIR-${tag}", if already created at time of error
    if [[ -v WDIR && -v NOW ]]; then
        if [ -d "${WDIR}/${NOW}" ]; then
            # purge working dir but keep tmp output dir
            if [[ -v CURR_DIR && -d "$CURR_DIR" && $KEEP == "false" ]]; then
                rm -r "$CURR_DIR"
            fi
            # rename out_dir and parent wdir
            mv "${OUT_DIR}" "${OUT_DIR}-${tag}"
            mv "${WDIR}/${NOW}" "${WDIR}/${NOW}-${tag}"
            # redefine OUT_DIR with new path
            OUT_DIR="${WDIR}/${NOW}-${tag}/pygl3d-bench_${NOW}-${tag}"

            echo -e "\n\nBenchmark working directory marked as '*-${tag}' !"
        fi
    fi
    if [[ -v SAVE_DIR && -d "$SAVE_DIR" ]]; then
        mv "$SAVE_DIR" "${SAVE_DIR}-${tag}"
        echo -e "\n\nBenchmark output directory marked as '*-${tag}' !"
    fi
    echo -e "\n\n"
}

# set a trap for ERR to call cleanup function
# manual trigger for ERR is call to `false`
trap bench_failed ERR


# save location of run_benchmark.sh script and cd there
SCRIPT_DIR=$(dirname -- ${BASH_SOURCE[0]})
cd "$SCRIPT_DIR"
SCRIPT_DIR=$(pwd)


# printf formatted help text as convenience function
# multiline descriptions indent '\' + 1 space

help_msg(){
    printf "\n %-9s%-17s" \
        "usage:" \
        "run_benchmark.sh"
    printf "%s\n" \
        "-o 'path' -w 'path' [-b {all,evolve,full,init}] [-d {cuda,numba,cython}]"
    printf "%27s%s\n" \
        "" "[-e 'path' | <conda env name>] [-f <version string>] [-h] [-k] [-m {0,1}]" \
        "" "[-r <number>] [-s 'path' | <version string>] [-t]"
    printf "\n %s\n" \
        "A fully automated and customizable benchmark for Pyglasma3d Simulations."
    printf "\n required arguments:\n\n"
    printf "%4s%-22s%s\n" \
        "" "-o 'path', --output 'path'" "" \
        "" "" "\ specify the output directory for benchmark results" \
        "" "-w 'path', --wdir 'path'" "" \
        "" "" "\ specify the temporary working directory." \
        "" "" "\ for fast performance on systems with enough memory (RAM)" \
        "" "" "\ use a 'tmpfs' mount."
    printf "\n optional arguments:\n\n"
    printf "%4s%-22s%s\n" \
        "" "-b {all,evolve,full,init}, --bench {all,evolve,full,init}" "" \
        "" "" "\ select the benchmark to run." \
        "" "" "\ - all: run all configured benchmarks" \
        "" "" "\ - evolve: run benchmark for simulation evolve steps" \
        "" "" "\ - full: run benchmark for full simulation setup" \
        "" "" "\ - init: run benchmark for simulation initialization" \
        "" "" "\ default: all"
    printf "%4s%-22s%s\n" \
        "" "-d {cuda,numba,cython}, --device {cuda,numba,cython}" "" \
        "" "" "\ set the target compute device. has to match the optionally supplied" \
        "" "" "\ argument for the source archive: -s 'path' | <version string>" \
        "" "" "\ default: cuda"
    printf "%4s%-22s%s\n" \
        "" "-e 'path' | <conda env name>, --env 'path' | <conda env name>" "" \
        "" "" "\ path to the python venv 'activate' file or name / prefix of the conda" \
        "" "" "\ env to use. For conda the virtual env will be stacked on top of any" \
        "" "" "\ currently active envs." \
        "" "" "\ CAUTION: the specified environment will get modified to match the" \
        "" "" "\ dependencies of the selected -s 'path' | <version string> !"
    printf "%4s%-22s%s\n" \
        "" "-f <version string>, --force <version string>" "" \
        "" "" "\ if -s 'path' is given, but 'path' cannot be verified (is a modified" \
        "" "" "\ version of the source code), force to run the benchmark anyway." \
        "" "" "\ the CONFIG.txt file will show <version string> as:" \
        "" "" "\ 'Repository archive version: !CUSTOM! <version string>'"
    printf "%4s%-22s%s\n" \
        "" "-h, --help" "show this help message and exit"
    printf "%4s%-22s%s\n" \
        "" "-k, --keep" "do not purge temporary working directory after script exits"
    printf "%4s%-22s%s\n" \
        "" "-m {0,1}, --fastmath {0,1}" "" \
        "" "" "\ enable (1) or disable (0) fastmath for the simulation" \
        "" "" "\ default: 1 (enabled)"
    printf "%4s%-22s%s\n" \
        "" "-r <number>, --repeat <number>" "" \
        "" "" "\ number of times to repeat the benchmark." \
        "" "" "\ default: 2"
    printf "%4s%-22s%s\n" \
        "" "-s 'path' | <version string>, --source 'path' | <version string>" "" \
        "" "" "\ path to the source archive to use for the benchmark or a valid git" \
        "" "" "\ tag '<version string>' from the repository. the selected tag has to" \
        "" "" "\ be compatible with the selected -d {cuda,numba,cython}." \
        "" "" "\ default: latest" \
        "" "" "\ available tags: >= v0.4.6"
    printf "%4s%-22s%s\n" \
        "" "-t, --test" \
        "runs a benchmark script that does not generate any load and is used" \
        "" "" "\ to check if all modules and dependencies are configured correctly." \
        "" "" "\ all output and result files will be generated and saved." \
        "" "" "\ virtual environments selected with -e 'path' | <conda env name> will" \
        "" "" "\ get modified to match the dependencies of the selected" \
        "" "" "\ -s 'path' | <version string !" \
        "" "" "\ WARNING: do not use together with -b {all,evolve,full,init} !"
    printf "\n dependencies:\n\n"
    printf "%4s%-22s%s\n" \
        "" "- Python interpreter:" "" \
        "" "" "for '-d {cuda,numba}': Version 3" \
        "" "" "for '-d cython': Version 2" \
        "" "- GNU 'time' command:" "" \
        "" "" "https://www.gnu.org/software/time/" \
        "" "- NVIDIA Driver and Cuda (via 'cudatoolkit'):" "" \
        "" "" "if in '-d cuda' mode" \
        "" "- 'virtualenv' Python package:" "" \
        "" "" "if in '-d cython' mode and not providing '-e 'path' | <conda env name>'" \
        "" "- GCC or equivalent C compiler:" "" \
        "" "" "if in '-d cython' mode"
    printf "\n\n"
}


# argument parsing
##################

# ${#XXX_ARGS[@]} == ${#XXX_ARGS_LONG[@]}
# every arg needs a short an long version and both arrays have to be the same length
# one colon for required values, two for optional values, none for no values (=> flag)
REQ_ARGS=( "-o:" "-w:" )
REQ_ARGS_LONG=( "--output:" "--wdir:" )
OPT_ARGS=( "-b:" "-d:" "-e:" "-f:" "-h" "-k" "-m:" "-r:" "-s:" "-t" )
OPT_ARGS_LONG=(
    "--bench:"
    "--device:"
    "--env:"
    "--fastmath:"
    "--force:"
    "--help"
    "--keep"
    "--repeat:"
    "--source:"
    "--test"
)

# generate getopt arguments

short_opts=""
long_opts=""

for i in ${!OPT_ARGS[@]}; do

    short_opts="${short_opts}$(tr -d '-' <<< ${OPT_ARGS[$i]})"
    long_opts="${long_opts}$(tr -d '-' <<< ${OPT_ARGS_LONG[$i]}),"
    # remove colons for later use of XXX_ARGS
    OPT_ARGS[$i]=$(tr -d ":" <<< ${OPT_ARGS[$i]})
    OPT_ARGS_LONG[$i]=$(tr -d ":" <<< ${OPT_ARGS_LONG[$i]})

done

for i in ${!REQ_ARGS[@]}; do

    short_opts="${short_opts}$(tr -d '-' <<< ${REQ_ARGS[$i]})"
    long_opts="${long_opts}$(tr -d '-' <<< ${REQ_ARGS_LONG[$i]}),"
    # remove colons for later use of XXX_ARGS
    REQ_ARGS[$i]=$(tr -d ":" <<< ${REQ_ARGS[$i]})
    REQ_ARGS_LONG[$i]=$(tr -d ":" <<< ${REQ_ARGS_LONG[$i]})

done

# parse args with getopt
parsed_args=$(getopt -n "run_benchmark.sh" -o $short_opts --long $long_opts -- "$@")
getopt_return=$?

# if parsing error by getopt
if [ "$getopt_return" != "0" ]; then
    help_msg
    false
fi

# eval required to honor spaces in arguments (and do not split there)
eval set -- "$parsed_args"


# use arguments to configure benchmark

# set optional args
BENCH="all"
DEVICE="cuda"
ENV="create new"
FM=1
KEEP="false"
REPEAT=2
VERSION="latest"

# set args
while [ $# -gt 1 ]; do
    case "$1" in
        -o | --output)
            SAVE_DIR_INPUT="$2"
            shift 2;;
        -w | --wdir)
            WDIR="$2"
            shift 2;;
        -b | --bench)
            BENCH="$2"
            shift 2;;
        -d | --device)
            DEVICE="$2"
            shift 2;;
        -e | --env)
            ENV="$2"
            shift 2;;
        -m | --fastmath)
            FM="$2"
            shift 2;;
        -f | --force)
            FORCE_RUN="true"
            CUSTOM_VER="$2"
            shift 2;;
        -h | --help)
            help_msg
            exit 0;;
        -k | --keep)
            KEEP="true"
            shift;;
        -r | --repeat)
            REPEAT="$2"
            shift 2;;
        -s | --source)
            VERSION="$2"
            shift 2;;
        -t | --test)
            BENCH="test"
            shift;;
        --)
            shift
            echo -e "Positional arguments are not allowed!\n$*"
            help_msg
            false;;
        *)
            echo -e "ERROR!\
                     \nThere was an internal error while parsing the arguments left:"
            echo "$*"
            echo -e "Make sure all allowed arguments are handled in the CASE switch!\n"
            false;;
    esac
done

# check if all required args are supplied
for i in ${!REQ_ARGS[@]}; do

    if [[ ! " $parsed_args " =~ " ${REQ_ARGS[$i]} " && \
          ! " $parsed_args " =~ " ${REQ_ARGS_LONG[$i]} " ]]; then
        echo -e "\nERROR!
                 \nThe required argument: \n'${REQ_ARGS[$i]}, ${REQ_ARGS_LONG[$i]}' \
                 \nis missing from the command line!"
        help_msg
        false
    fi

done


# verification of system dependencies
#####################################

# find location of first GNU 'time' command in $PATH
if ! TIME_PATH=$(which time 2> /dev/null); then
    echo -e "\nERROR!\nThe GNU 'time' command is not installed!"
    false
fi


# verification of supplied arguments
####################################


# check if $DEVICE is valid
VALID_DEVICES=( "cython" "cuda" "numba" )
if [[ ! " ${VALID_DEVICES[@]} " =~ " $DEVICE " ]]; then
    echo -e "\nERROR!"
    echo -e "The specified device:\n${DEVICE}\nis not valid!"
    false
fi


# check if $BENCH is valid
VALID_BENCHES=( "all" "evolve" "full" "init" "test" )
if [[ ! " ${VALID_BENCHES[@]} " =~ " $BENCH " ]]; then
    echo -e "\nERROR!"
    echo -e "The specified benchmark:\n${BENCH}\nis not valid!"
    false
fi


# check if $REPEAT is valid
NUM='^[0-9]+$'
if [[ ! $REPEAT =~ $NUM ]]; then
    echo -e "\nERROR!"
    echo -e "The specified number of repetitions:\n${REPEAT}\nis not valid!"
    false
fi
# set type of REPEAT to int
declare -i REPEAT


# check if $FM fastmath is valid
VALID_FM=( 0 1 )
if [[ ! " ${VALID_FM[@]} " =~ " $FM " ]]; then
    echo -e "\nERROR!"
    echo -e "The specified option for fastmath:\n${FM}\nis not valid!"
    false
fi


# check the supplied working dir
echo -e "\nVerifying working directory ..."
if [ ! -d "$WDIR" ]; then
    if mkdir "$WDIR"; then
        echo -e "Working directory successfully created!"
    else
        echo -e "\nERROR!"
        echo -e "The supplied path for the working directory:\n${WDIR}"
        echo -e "is not valid!"
        false
    fi
elif [ -w "$WDIR" ]; then
    echo "Working directory check passed!"
else
    echo -e "\nERROR!\nInsufficient permissions on the working directory:"
    ls -dlh "${WDIR}"
    false
fi

# save the timestamp for identifying this run
NOW=$(date +%Y-%m-%d_%H-%M-%S)
# expand possible relative paths
WDIR=$(cd "${WDIR}"; pwd)
# directory for this benchmark run, timestamp as name
mkdir "${WDIR}/${NOW}"
# working dir
CURR_DIR="${WDIR}/${NOW}/pygl3d-bench-WDIR_${NOW}"
mkdir "$CURR_DIR"
# temporary sim output, copied to output folder later
OUT_DIR="${WDIR}/${NOW}/pygl3d-bench_${NOW}"
mkdir "$OUT_DIR"

# check the supplied output (save) dir
echo -e "\nVerifying output directory ..."
if [ ! -d "$SAVE_DIR_INPUT" ]; then
    if mkdir "$SAVE_DIR_INPUT"; then
        echo -e "Output directory successfully created:\n${SAVE_DIR_INPUT}"
    else
        echo -e "\nERROR!"
        echo -e "The supplied path for the output directory:\n${SAVE_DIR_INPUT}"
        echo -e "is not valid!"
        false
    fi
elif [ -w "$SAVE_DIR_INPUT" ]; then
    echo "Output directory check passed!"
else
    echo -e "\nERROR!\nInsufficient permissions on the output directory:"
    echo -e $(ls -dlh "${SAVE_DIR_INPUT}")
    false
fi

# expand possible relative paths
SAVE_DIR_INPUT=$(cd "${SAVE_DIR_INPUT}"; pwd)


# verifying supplied source archives
#        or downloading if necessary
####################################

# TODO: after change to final repo:
# - recalculate and replace all sha sums for new repo
# - change all mentions of old gitlab repo paths to new repo
# TODO: automate adding new shasum to the file with gitlab ci
# TODO: outsource the sha to file(s)

# sha512 checksums for tags for numba version
# TODO: add checksum for v0.4.6
SHA512SUM_NUMBA=(
    e892e8793deab04999a0f307b1f7c4b83cb6c7abcc87da36bc262857449008cc45fcb2ae993b3e1c03127189e308ec16f8baaf91cb21d5cfe9e33c22d20d5851
    "NOT IMPLEMENTED"
)
NUMBA_TAGS=(
    "v0.4.5-benchmark"
    "v0.4.6"
)
# sha512 checksums for cython version:
# commit sha: dfc1fc5ee5294da14b28751d9cdf38f3bfa7ff6d 20.Apr.2018
SHA512SUM_CYTHON=(
    d4b8da13027e3e7a2652f9594a15558282de3933cb76489a8484af389d0cd690f93ee6ecf1fbc16b596f4f1eaa4dce2ca05b2cb292b0db254acb34e4462f2852
)

# check version and device
VERSION_STR="none"

if [[ $VERSION == "latest" ]]; then

    if [[ $DEVICE == "cuda" || $DEVICE == "numba" ]]; then

        VERSION_STR="latest [cuda|numba]"
        VERSION="${CURR_DIR}/pygl3d_numba-cuda.tar.gz"
        # download numba version to working dir
        echo -e "\nDownloading latest source archive ..."
        curl "https://gitlab.com/yumasheta/pyglasma3d_cuda_devel/-/archive/master/pyglasma3d_cuda_devel-master.tar.gz" \
        --output "$VERSION"
        echo -e "\nDownload of source archive finished successfully!"
    
    elif [[ $DEVICE == "cython" ]]; then

        VERSION_STR="monolithu/pyglasma3d [cython only]"
        VERSION="${CURR_DIR}/pygl3d_cy.tar.gz"
        # download cython version to working dir
        echo -e "\nDownloading latest source archive ..."
        curl "https://gitlab.com/monolithu/pyglasma3d/-/archive/master/pyglasma3d-master.tar.gz" \
        --output "$VERSION"
        echo -e "\nDownload of source archive finished successfully!"
    fi

elif [[ " ${NUMBA_TAGS[@]} " =~ " $VERSION " ]]; then
    # numba version checks out
    VERSION_STR="$VERSION [cuda|numba]"
    echo -e "\nSelected tag exists and is: $VERSION_STR"

    if [[ $DEVICE == "cuda" || $DEVICE == "numba" ]]; then

        echo -e "\nDownloading selected source archive ..."
        curl "https://gitlab.com/yumasheta/pyglasma3d_cuda_devel/-/archive/${VERSION}/pyglasma3d_cuda_devel-${VERSION}.tar.gz" \
        --output "${CURR_DIR}/pygl3d_numba.tar.gz"
        # set version after using tag in URL
        VERSION="${CURR_DIR}/pygl3d_numba.tar.gz"
        echo -e "\nDownload of source archive finished successfully!"

    else
        echo -e "\nERROR!\n"
        echo -e "This device:\n${DEVICE}\nis not supported by the version: \
                 \n${VERSION_STR}"
        false
    fi

elif [ -r "$VERSION" ]; then

    # verify the checksum against list of known values
    echo -e "\nSpecified path to source exists. Verifying checksum ..."
    check_sum=( $(sha512sum "$VERSION") )
    
    if [[ " ${SHA512SUM_CYTHON[@]} " =~ " ${check_sum[0]} " ]]; then
        # cython version checks out
        VERSION_STR="monolithu/pyglasma3d [cython only]"
        echo -e "The specified source archive checks out and is version:\n$VERSION_STR"

        # check if device is cython
        if [ $DEVICE != "cython" ]; then
            echo -e "\nERROR!\n"
            echo -e "This device:\n${DEVICE}\nis not supported by the version: \
                     \n${VERSION_STR}"
            false
        fi

    elif [[ " ${SHA512SUM_NUMBA[@]} " =~ " ${check_sum[0]} " ]]; then
        # numba version checks out
        # search for the checksum in list of checksums
        for i in "${!SHA512SUM_NUMBA[@]}"; do
           if [[ "${SHA512SUM_NUMBA[${i}]}" == "${check_sum[0]}" ]]; then
               NUMBA_V_IDX=${i};
           fi
        done

        VERSION_STR="${NUMBA_TAGS[${NUMBA_V_IDX}]} [cuda|numba]"
        echo -e "The specified source archive checks out and is version:\n$VERSION_STR"

        # check if device is cuda|numba
        if [[ $DEVICE != "cuda" && $DEVICE != "numba" ]]; then
            echo -e "\nERROR!\n"
            echo -e "This device:\n${DEVICE}\nis not supported by the version: \
                     \n${VERSION_STR}"
            false
        fi

    else
        echo -e "Checksum verification for:\n${VERSION}\nfailed!\n"
        if [[ $FORCE_RUN == "true" ]]; then
            echo "The option -f $CUSTOM_VER [--force $CUSTOM_VER] was set!"
            echo -e "The benchmark will continue ... \n"
            VERSION_STR="!CUSTOM! $CUSTOM_VER"
        else
            echo "If you wish to run a modified version of the source archive,"
            echo "use the -f <version string> [--force <version string>] option."
            false
        fi
    fi

else
    echo -e "\nERROR!\n"
    echo -e "The specified source archive:\n${VERSION}\ndoes not exist!"
    false
fi

echo -e "\nExtracting source archive to working directory ..."
CODE_SOURCE="${CURR_DIR}/repo"
mkdir "$CODE_SOURCE"
tar -xf "$VERSION" --strip-components=1 -C "$CODE_SOURCE"
echo "Source archive successfully extracted!"


# prepare execution environment
###############################

test_python_version(){
    # get python version as string X.X.X
    PY_VER=$(python -c "import sys; print('.'.join(map(str, sys.version_info[:3])))")

    if [ "$DEVICE" == "cython" ]; then
        # cython version needs py2 > 2.7.9
        # this will exit 0 if 2.7.9 is smaller or equal to PY_VER, thus negate
        if ! printf '%s\n' "2.7.9" "$PY_VER" | sort --version-sort --check=quiet \
        || [ ${PY_VER::1} != "2" ]; then
            echo -e "\nERROR!\n"
            echo "The specified virtual environment is not supported by the device:"
            echo -e "${DEVICE} [Python2 > 2.7.9]"
            false
        fi
    else
        # cuda | numba need py3
        # read minimum python version from first line in requirements.txt
        # TODO: change for final repo
        PY_VER_MIN=$(sed -n -e 's/# python==//p' \
        "${CODE_SOURCE}/pyglasma3d_numba/pip-requirements.txt")

        if [ -z "$PY_VER_MIN" ]; then
            echo -e "\nERROR!\n"
            echo "The pip-requirements.txt file of the source archive is missing the"
            echo "specification for the minimum Python version!"
            false
        fi

        # this will exit 0 if PY_VER_MIN is smaller or equal to PY_VER, thus negate
        if ! printf '%s\n' "$PY_VER_MIN" "$PY_VER" | sort --version-sort --check=quiet;
        then
            echo -e "\nERROR!\n"
            echo "The specified virtual environment is not supported by the device:"
            echo -e "${DEVICE} [Python > $PY_VER_MIN]"
            false
        fi
    fi
}


# env creation is based on install status of conda
if which conda &> /dev/null; then
    # conda is installed
    # import conda functions
    source "$(conda info --base)/etc/profile.d/conda.sh"

    if [ "$ENV" == "create new" ]; then

        echo -e "\nCreating new conda environment ..."

        if [ "$DEVICE" == "cython" ]; then
            conda env create --prefix "${CURR_DIR}/venv" \
            --file conda-cython-environment.yml
        else
            # device is cuda or numba
            # TODO: change for final repo
            conda env create --prefix "${CURR_DIR}/venv" \
            --file "${CODE_SOURCE}/pyglasma3d_numba/conda-environment.yml"
        fi
        conda activate --stack "${CURR_DIR}/venv"
        VIRTUAL_ENV=$CONDA_PREFIX
        echo -e "\nVirtual environment successfully created!"

    elif conda activate --stack "$ENV" > /dev/null ; then

        echo -e "\nSuccessfully activated specified virtual environment!"
        echo -e "\nInstalling required conda packages ..."

        # if ENV is prefix path, change conda command
        if [ -d "$ENV" ]; then
            name_or_prefix="--prefix"
        else
            name_or_prefix="--name"
        fi

        if [ "$DEVICE" == "cython" ]; then
            conda env update $name_or_prefix "$ENV" --file conda-cython-environment.yml
        else
            conda env update $name_or_prefix "$ENV" \
            --file "${CODE_SOURCE}/pyglasma3d_numba/conda-environment.yml"
        fi

        test_python_version

        VIRTUAL_ENV=$CONDA_PREFIX
        echo -e "\nSuccessfully installed conda packages!"

    else
        # $ENV does not match allowed values for conda venvs
        echo -e "\nERROR!\n"
        echo -e "The specified virtual environment:\n${ENV}\ncould not be solved!"
        echo "In conda mode only the name or prefix of an existing conda environment"
        echo "is allowed as the value to -e 'path' [--env 'path']!"
        false
    fi

else
    # conda is not installed, use python envs

    if [ "$ENV" == "create new" ]; then

        echo -e "\nCreating new virtual environment ..."

        if [ "$DEVICE" == "cython" ]; then
            # check for virtualenv package
            if ! which virtualenv &> /dev/null; then
                echo -e "\nERROR!\nThe virtualenv package is required for creating a"
                echo "new virtual environment in device=cython mode!"
                false
            fi

            # create virtualenv on python2 with requirements
            virtualenv -p "python2.7" "${CURR_DIR}/venv"
            source "${CURR_DIR}/venv/bin/activate"
            pip install -r "cython-pip-requirements.txt"

        else
            # device is cuda or numba
            # create venv based on pip requirements of source archive
            python3 -m venv "${CURR_DIR}/venv"
            source "${CURR_DIR}/venv/bin/activate"
            # TODO: change for final repo
            pip install -r "${CODE_SOURCE}/pyglasma3d_numba/pip-requirements.txt"
        fi

        test_python_version
        echo -e "\nVirtual environment successfully created!"

    elif [ -r "$ENV" ]; then

        echo -e "\nActivating specified virtual environment ..."
        # activate given py venv based on 'activate' file
        source "$ENV"
        test_python_version

        echo -e "\nSuccessfully activated specified virtual environment!"
        echo -e "\nInstalling required pip packages ..."

        if [ "$DEVICE" == "cython" ]; then
            pip install -r "cython-pip-requirements.txt"
        else
            # TODO: change for final repo
            pip install -r "${CODE_SOURCE}/pyglasma3d_numba/pip-requirements.txt"
        fi
        echo -e "\nSuccessfully installed pip packages!"

    else
        # $ENV does not match allowed values for python venvs
        echo -e "\nERROR!\n"
        echo -e "The specified virtual environment:\n${ENV}\ncould not be solved!"
        echo "In Python mode only a path to an existing 'activate' file for a Python"
        echo "venv environment is allowed as the value to -e 'path' [--env 'path']!"
        false
    fi
fi


# save config to tmp OUT_DIR
############################

echo -e "\nDumping configuration to file ..."

sep_str="\n$(printf "%.s-" {1..80})\n"

# dump config to file
:> "${OUT_DIR}/CONFIG.txt"

{ \
echo "CONFIGURATION PARAMETERS:"; echo -e $sep_str; \

echo -e "Arguments for run_benchmark.sh:\n${parsed_args}"; echo -e $sep_str; \

echo -e "Repository archive version:\n${VERSION_STR}"; echo -e $sep_str; \

echo -e "Active virtual environment:\n${VIRTUAL_ENV}"; echo -e $sep_str; \

echo -e "Python version:"; \
echo -e "$(python -c 'import sys; print([x for x in sys.version_info])')"; \
echo -e $sep_str; \

echo -e "pip package list:\n$(pip freeze)"; echo -e ${sep_str}; \

echo "System Parameters:"; \

echo -e "\nOS:"; uname -srvmo; \
echo -e "\nCPU:"; lscpu; \
echo -e "\nMEMORY:"; free -m; \

echo -e $sep_str; \
} >> "${OUT_DIR}/CONFIG.txt"

if [[ "$DEVICE" == "cuda" || "$DEVICE" == "numba" ]]; then

    echo -e "Numba System INFO:\n" >> "${OUT_DIR}/CONFIG.txt"
    # get numba -s output
    # strip the part between '-' and save to file
    sed_sep_str=$(printf "%.s-" {1..80})
    sed_cmd="/${sed_sep_str}/,/${sed_sep_str}/p"
    tmp_out=$(sed -n -e $sed_cmd <<< "$(numba -s)")

    { sed -e '1d' <<< "$tmp_out"; echo; } >> "${OUT_DIR}/CONFIG.txt"

    if [ "$DEVICE" == "cuda" ]; then

        { \
        echo "GPU NVSMI LOG:"; \
        sed -e '/Processes/,$d; /NVSMI LOG/,+1d' <<< "$(nvidia-smi -q)"; \
        echo -e $sep_str; \
        } >> "${OUT_DIR}/CONFIG.txt"

        if which nvidia-settings &> /dev/null; then
            { \
            echo -e "GPU:"; \
            nvidia-settings -q gpus; \

            sed -n -e "/Attribute '[A-z]\+'/ s/$/ MT\/s\\n/p" \
            <<< "$(nvidia-settings -q PCIEMaxLinkSpeed)"; \

            sed -n -e "/Attribute '[A-z]\+'/ s/$/ Lanes\\n/p" \
            <<< "$(nvidia-settings -q PCIECurrentLinkWidth)"; \

            sed -n -e "/Attribute '[A-z]\+'/ s/$/\\n/p" \
            <<< "$(nvidia-settings -q PCIEGen)"; \

            sed -n -e "/Attribute '[A-z]\+'/ s/$/ MB\\n/p" \
            <<< "$(nvidia-settings -q TotalDedicatedGPUMemory)"; \

            sed -n -e "/Attribute '[A-z]\+'/ s/$/ Bit\\n/p" \
            <<< "$(nvidia-settings -q GPUMemoryInterface)"; \

            sed -n -e "/Attribute '[A-z]\+'/ s/$/\\n/p" \
            <<< "$(nvidia-settings -q CUDACores)"; \

            tmp_out=$(nvidia-settings -q GPUPerfModes -d); \
            tmp_out=$(sed -e '1d' -e 's/perf=[0-9]\+,/\'$'\n  &\\n    /g' \
            <<< "$tmp_out"); \

            sed -e "s/Attribute '[A-z]\+'/\\n  &/g" <<< "$tmp_out"; \

            echo -e $sep_str; \
            } >> "${OUT_DIR}/CONFIG.txt"
        fi
    fi
fi


# BENCHMARK
###########

# wait for cached IO to finish before starting benchmark
echo -e "\nSyncing working directory IO ..."
sync -f "$WDIR"

# benchmark settings

# steps
SIM_STEPS=( 2 4 8 )
# SIM_STEPS=( 2 )

# longitudinal grid sizes
SIM_L=( 32 64 128 256 512 1024 2048 )
# SIM_L=( 32 32 )

# transversal gird sizes
SIM_T=( 512 256 256 128 128 64 64 )
# SIM_T=( 64 64 )

# GPU MEMORY consumption for computation
# GB = ( 5.5 2.8 5.5 2.8 5.5 2.8 5.5 )

# number of times the sim will run
declare -i RUN_NUMBER="${#SIM_STEPS[@]}*${#SIM_T[@]}*${REPEAT}"
declare -i RUN_CURR

# create folder for timing results
mkdir "${OUT_DIR}/timings"


# benchmark functions
#####################


backup_wdir(){
    # save backup of CODE_SOURCE
    cp -r "$CODE_SOURCE" "${CODE_SOURCE}_backup"
    # sync again after cp
    sync -f "$WDIR"
}

main_bench(){
    # one argument: name of subfolder for simlogs

    # sim config string, inherited from outer (global) scope
    SIM_CONF="-d ${DEVICE} --fastmath ${FM} -l ${SIM_L[${i}]} -t ${SIM_T[${i}]} -s ${s}"

    # repeat bench
    declare -i j
    for ((j=1;j<=REPEAT;++j)); do

        # build format string for time command
        format_str="{\n\"conf\": \"${SIM_CONF}\",\n\"rep\": ${j},\n\"timings\": "
        format_str="${format_str}{\"real\": %e, \"usr\": %U, \"sys\": %S, "
        format_str="${format_str}\"embedded\": null}\n},"
        # save timings formatted as json object with all necessary
        # identification data to file
        $TIME_PATH -f "$format_str" -a -o "${OUT_DIR}/timings/${1}.dat" \
        python -m "$PATH_TO_BENCH" $SIM_CONF \
        > "${OUT_DIR}/${1}/simlog-${DEVICE}-fm${FM}-l${SIM_L[${i}]}-t${SIM_T[${i}]}-s${s}-${j}.txt"
        # echo "debug ${j}" \

        if [ -r embedded_result.dat ]; then
            # replace ebedded timing placeholder 'null', if embedded results exists
            EMBED_RESULT=$(cat embedded_result.dat)
            sed -i 'x; ${s/null/'"${EMBED_RESULT}"'/;p;x}; 1d' \
            "${OUT_DIR}/timings/${1}.dat"
            rm embedded_result.dat
        fi

        # delete modified CODE_SOURCE
        rm -r "$CODE_SOURCE"
        # restore backup of CODE_SOURCE
        cp -r "${CODE_SOURCE}_backup" "$CODE_SOURCE"
        # necessary to refresh wdir, as wdir got deleted and replaced
        cd "$(pwd)"
        # sync again after cp
        sync -f "$WDIR"

        # print progress and increment counter
        echo -ne "\t$((100*RUN_CURR/RUN_NUMBER))% completed\r"
        ((RUN_CURR++))

    done
}

run_init_bench(){
    echo -e "\nStarted benchmark for simulation initialization ...\n"
    # print progress
    echo -ne "\t0% completed\r"

    # create simlog output dir
    mkdir "${OUT_DIR}/init_bench"

    # set run counter
    RUN_CURR=1

    if [ "$DEVICE" == "cython" ]; then

        # copy benchmark setup to wdir
        cp "mv_init_bench.py" "${CODE_SOURCE}/pyglasma3d/examples/"
        PATH_TO_BENCH="pyglasma3d.examples.mv_init_bench"
        cd "$CODE_SOURCE"

        echo -e "Compiling cython files ... \n\n"
        # compile
        $TIME_PATH -f "{\n\"timing\": {\"real\": %e, \"usr\": %U, \"sys\": %S}\n}" \
        -o "${OUT_DIR}/timings/init_bench-compile.json" \
        ./setup.sh

        echo -e "\nRunning benchmark for simulation initialization ...\n"
        echo -ne "\t0% completed\r"

        # saving backup of CODE_SOURCE
        backup_wdir

        # loop through all configs
        for s in ${SIM_STEPS[@]}; do
            for i in ${!SIM_L[@]}; do
                main_bench "init_bench"
            done
        done

    else

        # copy benchmark setup to wdir
        # TODO: change for final repo
        cp "mv_init_bench.py" "${CODE_SOURCE}/pyglasma3d_numba/examples/"
        PATH_TO_BENCH="examples.mv_init_bench"
        cd "${CODE_SOURCE}/pyglasma3d_numba"

        # saving backup of CODE_SOURCE
        backup_wdir

        # loop through all configs
        for s in ${SIM_STEPS[@]}; do
            for i in ${!SIM_L[@]}; do
                main_bench "init_bench"
            done
        done

    fi


    echo -e "\n\nBenchmark for simulation initialization completed!"
}

run_evolve_bench(){
    echo -e "\nStarted benchmark for simulation evolve steps ...\n"
    # print progress
    echo -ne "\t0% completed\r"

    # create simlog output dir
    mkdir "${OUT_DIR}/evolve_bench"

    # set run counter
    RUN_CURR=1

    if [ "$DEVICE" == "cython" ]; then

        # copy benchmark setup to wdir
        cp "mv_evolve_bench.py" "${CODE_SOURCE}/pyglasma3d/examples/"
        PATH_TO_BENCH="pyglasma3d.examples.mv_evolve_bench"
        cd "$CODE_SOURCE"

        echo -e "Compiling cython files ... \n\n"
        # compile
        $TIME_PATH -f "{\n\"timing\": {\"real\": %e, \"usr\": %U, \"sys\": %S}\n}" \
        -o "${OUT_DIR}/timings/evolve_bench-compile.json" \
        ./setup.sh

        echo -e "\nRunning benchmark for simulation evolve steps ...\n"
        echo -ne "\t0% completed\r"

        # saving backup of CODE_SOURCE
        backup_wdir

        # loop through all configs
        for s in ${SIM_STEPS[@]}; do
            for i in ${!SIM_L[@]}; do
                main_bench "evolve_bench"
            done
        done

    else

        # copy benchmark setup to wdir
        # TODO: change for final repo
        cp "mv_evolve_bench.py" "${CODE_SOURCE}/pyglasma3d_numba/examples/"
        PATH_TO_BENCH="examples.mv_evolve_bench"
        cd "${CODE_SOURCE}/pyglasma3d_numba"

        # saving backup of CODE_SOURCE
        backup_wdir

        # loop through all configs
        for s in ${SIM_STEPS[@]}; do
            for i in ${!SIM_L[@]}; do
                main_bench "evolve_bench"
            done
        done

    fi

    echo -e "\n\nBenchmark for simulation evolve steps completed!"
}

run_full_bench(){
    echo -e "\nStarted benchmark for full simulation run ...\n"
    # print progress
    echo -ne "\t0% completed\r"

    # create simlog output dir
    mkdir "${OUT_DIR}/full_bench"

    # set run counter
    RUN_CURR=1

    if [ "$DEVICE" == "cython" ]; then

        # copy benchmark setup to wdir
        cp "mv_full_bench.py" "${CODE_SOURCE}/pyglasma3d/examples/"
        PATH_TO_BENCH="pyglasma3d.examples.mv_full_bench"
        cd "$CODE_SOURCE"

        echo -e "Compiling cython files ... \n\n"
        # compile
        $TIME_PATH -f "{\n\"timing\": {\"real\": %e, \"usr\": %U, \"sys\": %S}\n}" \
        -o "${OUT_DIR}/timings/full_bench-compile.json" \
        ./setup.sh

        echo -e "\nRunning benchmark for full simulation run ...\n"
        echo -ne "\t0% completed\r"

        # saving backup of CODE_SOURCE
        backup_wdir

        # loop through all configs
        for s in ${SIM_STEPS[@]}; do
            for i in ${!SIM_L[@]}; do
                main_bench "full_bench"
            done
        done

    else

        # copy benchmark setup to wdir
        # TODO: change for final repo
        cp "mv_full_bench.py" "${CODE_SOURCE}/pyglasma3d_numba/examples/"
        PATH_TO_BENCH="examples.mv_full_bench"
        cd "${CODE_SOURCE}/pyglasma3d_numba"

        # saving backup of CODE_SOURCE
        backup_wdir

        # loop through all configs
        for s in ${SIM_STEPS[@]}; do
            for i in ${!SIM_L[@]}; do
                main_bench "full_bench"
            done
        done

    fi

    echo -e "\n\nBenchmark for full simulation run completed!"
}

run_test_bench(){
    echo -e "\nStarted test for module and dependency configuration ...\n"
    # print progress
    echo -ne "\t0% completed\r"

    # create simlog output dir
    mkdir "${OUT_DIR}/test_bench"

    # set run counter
    RUN_CURR=1

    if [ "$DEVICE" == "cython" ]; then

        # copy benchmark setup to wdir
        cp "mv_test_setup.py" "${CODE_SOURCE}/pyglasma3d/examples/"
        PATH_TO_BENCH="pyglasma3d.examples.mv_test_setup"
        cd "$CODE_SOURCE"

        echo -e "Compiling cython files ... \n\n"
        # compile
        $TIME_PATH -f "{\n\"timing\": {\"real\": %e, \"usr\": %U, \"sys\": %S}\n}" \
        -o "${OUT_DIR}/timings/test_bench-compile.json" \
        ./setup.sh

        echo -e "\nRunning test for module and dependency configuration ...\n"
        echo -ne "\t0% completed\r"

        # saving backup of CODE_SOURCE
        backup_wdir

        # loop through all configs
        for s in ${SIM_STEPS[@]}; do
            for i in ${!SIM_L[@]}; do
                main_bench "test_bench"
            done
        done

    else

        # copy benchmark setup to wdir
        # TODO: change for final repo
        cp "mv_test_setup.py" "${CODE_SOURCE}/pyglasma3d_numba/examples/"
        PATH_TO_BENCH="examples.mv_test_setup"
        cd "${CODE_SOURCE}/pyglasma3d_numba"

        # saving backup of CODE_SOURCE
        backup_wdir

        # loop through all configs
        for s in ${SIM_STEPS[@]}; do
            for i in ${!SIM_L[@]}; do
                main_bench "test_bench"
            done
        done

    fi

    echo -e "\n\nTest for module and dependency configuration completed!"
}


case "$BENCH" in
    all)
        # create additional backup for mixing benchmarks
        cp -r "$CODE_SOURCE" "${CODE_SOURCE}_backup_all"

        run_init_bench

        # clean up after benchmark
        cd "$SCRIPT_DIR"
        # remove modified CODE_SOURCE
        rm -r "$CODE_SOURCE"
        rm -r "${CODE_SOURCE}_backup"
        cp -r "${CODE_SOURCE}_backup_all" "$CODE_SOURCE"
        
        run_evolve_bench
        
        # clean up after benchmark
        cd "$SCRIPT_DIR"
        # remove modified CODE_SOURCE
        rm -r "$CODE_SOURCE"
        rm -r "${CODE_SOURCE}_backup"
        cp -r "${CODE_SOURCE}_backup_all" "$CODE_SOURCE"
        
        run_full_bench;;

    evolve)
        run_evolve_bench;;
    full)
        run_full_bench;;
    init)
        run_init_bench;;
    test)
        run_test_bench
        bench_failed "test-run";;
    *)
        echo -e "ERROR!\
                \nThere was an internal error while selecting the benchmark:"
        echo $BENCH
        echo -e "This should not happen!"
        false;;
esac


# generate results json file
############################

# merge any compile timings into results file
FILE_COMPILE="${OUT_DIR}/bench_compile_results.json"
echo "{" > "$FILE_COMPILE"

for filename in "${OUT_DIR}"/timings/*-compile.json; do
    # get type of bench from filename
    bench_str=$(basename "$filename" .json)
    bench_str=${bench_str%"-compile"}
    if [ "$bench_str" == "*" ]; then
        # no files found
        break
    fi
    # write data to results file
    { echo "\"${bench_str}\":"; cat "$filename"; echo ","; } >> "$FILE_COMPILE"
done
# remove last comma
sed -i '$ s/,$//' "$FILE_COMPILE"
echo "}" >> "$FILE_COMPILE"


FILE="${OUT_DIR}/bench_results.json"
echo "{" > "$FILE"
echo "\"device\": \"${DEVICE}\"," >> "$FILE"

for filename in "${OUT_DIR}"/timings/*.dat; do
    # get type of bench from filename
    bench_str=$(basename "$filename" .dat)
    # remove last comma
    sed -i '$ s/,$//' "$filename"
    # write data to results file
    { echo "\"${bench_str}\": ["; cat "$filename"; echo "],"; } >> "$FILE"
done
# remove last comma
sed -i '$ s/,$//' "$FILE"
echo "}" >> "$FILE"


# copy results to SAVE_DIR
##########################
SAVE_DIR="${SAVE_DIR_INPUT}/"$(basename "${OUT_DIR}")
echo -e "\nSaving results to: ${SAVE_DIR}"
mkdir "$SAVE_DIR"
cp -r "${OUT_DIR}/"* "$SAVE_DIR"


# purge working dir
if [[ -d "$CURR_DIR" && $KEEP == "false" ]]; then
    echo -e "\nCleaning up working directory ..."
    rm -r "$CURR_DIR"
fi

echo -e "\nBenchmark finished successfully. The results are saved at:\n${SAVE_DIR}\n\n"