#!/bin/bash
#
# Run benchmarks and generate output page
#
set -eu

# test_mode: run a bench without checking for commits
test_mode=false

BENCHDIR=~/nimbench
ORIGDIR=$(pwd)
BENCHSRC=$(pwd)/benchmarks  # .nim benchmark runners

mkdir -p website/output

if [[ ! -d $BENCHDIR ]]; then
    (
    mkdir -p $BENCHDIR
    cd $BENCHDIR
    echo "Fetching and building Nim for the first time"
    git clone git://github.com/nim-lang/Nim.git
    cd Nim
    git clone --depth 1 git://github.com/nim-lang/csources
    cd csources
    sh build.sh
    )
fi

[ -f generate_bench_page ] || "$BENCHDIR"/Nim/bin/nim c -d:release generate_bench_page.nim

[ -f run_benchmarks ] || "$BENCHDIR"/Nim/bin/nim c -d:release run_benchmarks.nim

cd $BENCHDIR
cd Nim
git fetch
LOCAL_COMMITTISH=$(git rev-parse HEAD)
REMOTE_COMMITTISH=$(git rev-parse @{u})

if [ "$test_mode" = false ]; then

    [[ $LOCAL_COMMITTISH == $REMOTE_COMMITTISH ]] && exit 0

    git pull
    cd csources
    git pull

    sh build.sh
fi

rm $BENCHSRC/nimcache -rf

cd $ORIGDIR

[ "$test_mode" = true ] && LOCAL_COMMITTISH="test"
PATH=$PATH:"$BENCHDIR"/Nim/bin ./run_benchmarks $LOCAL_COMMITTISH
