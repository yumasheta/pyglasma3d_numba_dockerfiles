"""BENCHMARK VERSION.

This will not create any load and is used to validate the system setup
and dependencies for benchmarking.
"""

from __future__ import print_function

import os
import time
import argparse
import numpy as np


# command line arguments parsing with argparse

# helper function to check steps arg
def check_steps(arg):
    """Checker for steps argument."""
    try:
        arg = int(arg)
        if arg % 2 == 0 and arg >= 2:
            return arg
        raise argparse.ArgumentTypeError("{} is not a multiple of 2".format(arg))
    except ValueError:
        raise argparse.ArgumentTypeError(
            "invalid check_steps value steps={}".format(arg)
        )


# TODO: reorder args, like mv_gpu. alphabetic in categories
# set up argparse
parser = argparse.ArgumentParser(
    description="A benchmark setup script.",
    formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    prog="python -m examples.mv_full_bench",
)
parser.add_argument(
    "-o",
    "--output",
    type=str,
    default="mv_full_bench",
    metavar="<name>",
    dest="run",
    help='specify the <name> for the output file in "./output/T_<name>.dat"',
)
parser.add_argument(
    "-l", "--nl", type=int, default=64, dest="nx", help="longitudinal grid size"
)
parser.add_argument(
    "-t", "--nt", type=int, default=256, dest="nt", help="transverse grid size"
)
parser.add_argument(
    "-L",
    "--LL",
    type=float,
    default=6.0,
    dest="LL",
    help="longitudinal simulation box size in [fm]",
)
parser.add_argument(
    "-T",
    "--LT",
    type=float,
    default=6.0,
    dest="LT",
    help="transverse simulation box size in [fm]",
)
parser.add_argument(
    "-E",
    "--energy",
    type=float,
    default=200000.0,
    dest="sqrts",
    help="collision energy [MeV]",
    metavar="energy",
)
parser.add_argument("-m", type=float, default=200.0, help="infrared regulator [MeV]")
parser.add_argument(
    "-u",
    "--uv",
    type=float,
    default=10000.0,
    dest="uv",
    help="ultraviolet regulator [MeV]",
)
parser.add_argument(
    "-s",
    "--steps",
    type=check_steps,
    default=4,
    dest="steps",
    help="ratio between dt and aL in multiples of 2, has to be integer",
)
parser.add_argument(
    "--debug", action="store_true", help="set debug mode for verbose output"
)
parser.add_argument(
    "-d",
    "--device",
    type=str,
    default=os.environ.get("MY_NUMBA_TARGET", "cuda"),
    dest="device",
    choices=["cuda", "numba", "cython"],
    help="set the target compute device; "
    'this will set the environment variable "MY_NUMBA_TARGET"'
    "and run the appropriate code for each device.",
)
parser.add_argument(
    "--fastmath",
    type=int,
    default=os.environ.get("FASTMATH", 1),
    dest="fastmath",
    choices=[0, 1],
    help="configure use of fastmath; "
    'this will set the environment variable "FASTMATH"',
)

# parse args
args = parser.parse_args()

# evaluate environment variables to control numba

# set MY_NUMBA_TARGET
os.environ["MY_NUMBA_TARGET"] = args.device
# set FASTMATH
os.environ["FASTMATH"] = str(args.fastmath)


# simulation setup

# simulation specific imports have to occur after command line args
# have been evaluated (for numba target etc.)
# disable flake8 and pylint errors for that
# pylint: disable=wrong-import-position,import-error,unused-import
if args.device == "cython":
    import pyglasma3d.cy.mv as mv
    import pyglasma3d.cy.interpolate as interpolate
    import pyglasma3d.cy.gauss as gauss
    from pyglasma3d.core import Simulation
else:
    # device == cuda | numba
    import pyglasma3d_numba_source.interpolate as interpolate  # noqa: E402,F401
    import pyglasma3d_numba_source.gauss as gauss  # noqa: E402,F401
    import pyglasma3d_numba_source.mv as mv  # noqa: E402,F401
    from pyglasma3d_numba_source.core import Simulation  # noqa: E402,F401

    # check cuda libs, if codatoolkit is properly installed
    from numba.cuda.cudadrv import libs  # noqa: E402,F401

    cuda_libs = ("cublas", "cusparse", "cufft", "curand", "nvvm")
    try:
        print("\nTesting availability of cuda libraries ...")
        tuple(map(libs.open_cudalib, cuda_libs))
    except:  # pylint: disable=bare-except # noqa: E722
        print("\nERROR\nLoading cuda libraries failed!\n\n")
        raise


# values inherited from the command line arguments

# filename
# data will end up in `./output/T_<run>.dat`
# run = 'mv_trial_gpu'  ==> args.run

# grid size (make sure that ny == nz): args.nx, args.nt, args.nt
# nx, ny, nz = 2048, 64, 64   # 3.87 GB
# nx, ny, nz = 2048, 32, 32   # 0.97 GB
# nx, ny, nz = 512, 128, 128   # 3.87 GB
# nx, ny, nz = 128, 128, 128   # 0.97 GB
# nx, ny, nz = 64, 256, 256   # 1.92 GB  ==> default
# nx, ny, nz = 64, 512, 512   # >8 GB

# transverse and longitudinal box widths [fm]
# LT = 6.0  ==> args.LT
# LL = 6.0  ==> args.LL

# collision energy [MeV]
# sqrts = 200.0 * 1000.0  ==> args.sqrts

# infrared and ultraviolet regulator [MeV]
# m = 200.0 ==> args.m
# uv = 10.0 * 1000.0  ==> args.uv

# ratio between dt and aL [int, multiple of 2]
# steps = 4  ==> args.steps

# option for debug
# debug = True  ==> args.debug


# The rest of the parameters are computed automatically.

# constants
hbarc = 197.3270  # hbarc [MeV*fm]
RAu = 7.27331  # Gold nuclear radius [fm]

# determine lattice spacings and energy units
aT_fm = args.LT / args.nt
E0 = hbarc / aT_fm
aT = 1.0
aL_fm = args.LL / args.nx
aL = aL_fm / aT_fm
a = [aL, aT, aT]
dt = aL / args.steps

# determine initial condition parameters
gamma = args.sqrts / 2000.0
Qs = np.sqrt((args.sqrts / 1000.0) ** 0.25) * 1000.0
alphas = 12.5664 / (18.0 * np.log(Qs / 217.0))
g = np.sqrt(12.5664 * alphas)
mu = Qs / (g * g * 0.75) / E0
uvt = args.uv / E0
ir = args.m / E0
sigma = RAu / (2.0 * gamma) / aL_fm * aL
sigma_c = sigma / aL

# output file path
file_path = "./output/T_" + args.run + ".dat"

# Simulation loop
print("\nStarting mock simulation loop:\n")

max_iters = 20
t = time.time()
for it in range(max_iters):

    # this for loop moves the nuclei exactly one grid cell
    for step in range(args.steps):
        t = time.time()
        print(args.steps * it + step)
        print("Complete cycle in:", round(time.time() - t, 3))
