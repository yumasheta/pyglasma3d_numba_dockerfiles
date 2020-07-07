FROM nvidia/cuda:10.2-base

LABEL description="This image contains all dependencies of pyglasma3d_numba v0.4.5 and is used for benchmarks."
LABEL from="nvidia/cuda10.2-base"
LABEL maintainer="Kayran Schmidt / yumasheta"
LABEL runopts="docker run -it --gpus all --rm -v host_path/to/results:/results --tmpfs /wdir:exec this-image --bench --opts"
LABEL version="v0.4.5-benchmark"

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends wget bzip2 curl \
    && rm -rf /var/lib/apt/lists/*

COPY conda-environment.yml /benchmark/

ENV PATH /opt/conda/bin:$PATH

RUN wget --quiet https://repo.continuum.io/miniconda/Miniconda3-latest-Linux-x86_64.sh -O Miniconda.sh \
    && /bin/bash Miniconda.sh -b -p /opt/conda \
    && conda init bash \
    && conda install -y -c conda-forge time \
    && conda env update --prefix /opt/conda/ --file /benchmark/conda-environment.yml \
    && conda clean --all -y \
    && rm -f Miniconda.sh

COPY . /benchmark/

VOLUME [ "/results", "/wdir" ]

WORKDIR /benchmark
ENTRYPOINT [ "/bin/bash", "run_benchmark.sh", "--output", "/results", "--wdir", "/wdir", "--env", "base" ]
# CMD [ "--source", "pygl3d_XXXX", "--bench", "all", "--device", "cuda", "--test" ]