ARG UBUNTU_VERSION=18.04
ARG UBUNTU_IMAGE_DIGEST=646942475da61b4ce9cc5b3fadb42642ea90e5d0de46111458e100ff2c7031e6

FROM ubuntu:${UBUNTU_VERSION}@sha256:${UBUNTU_IMAGE_DIGEST}

ARG MINICONDA_VERSION=4.12.0
ARG CONDA_PY_VERSION=38
ARG CONDA_PKG_VERSION=4.13.0
ARG PYTHON_VERSION=3.10.13
ARG PYARROW_VERSION=10.0.1
ARG MLIO_VERSION=v0.8.0

# Install python and other scikit-learn runtime dependencies
# Dependency list from http://scikit-learn.org/stable/developers/advanced_installation.html#installing-build-dependencies
RUN apt-get update && \
    apt-get -y upgrade && \
    apt-get -y install --no-install-recommends \
        build-essential \
        curl \
        git \
        jq \
        libatlas-base-dev \
        nginx \
        openjdk-8-jdk-headless \
        unzip \
        wget \
        && \
    apt-get -y install --no-install-recommends \
        apt-transport-https \ 
        ca-certificates \
    gnupg \
        software-properties-common \
        autoconf \
        automake \
        build-essential \
        libssl-dev \
        && \
    # MLIO build dependencies
    # Official Ubuntu APT repositories do not contain an up-to-date version of CMake required to build MLIO.
    # Kitware contains the latest version of CMake.
    wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null | \
        gpg --dearmor - | \
        tee /etc/apt/trusted.gpg.d/kitware.gpg >/dev/null && \
    apt-add-repository 'deb https://apt.kitware.com/ubuntu/ bionic main' && \
    wget https://cmake.org/files/v3.18/cmake-3.18.4.tar.gz && \
    tar -xzvf cmake-3.18.4.tar.gz && \
    cd cmake-3.18.4 && \
    ./configure && \
    make -j$(nproc) && \
    make install && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        cmake-data=3.18.4-0kitware1 \
        doxygen \
        kitware-archive-keyring \
        libcurl4-openssl-dev \
        libtool \
        ninja-build \
        python3-dev \
        python3-distutils \
        python3-pip \
        zlib1g-dev \
        && \
    rm /etc/apt/trusted.gpg.d/kitware.gpg && \
    rm -rf /var/lib/apt/lists/*

# http://ftp.us.debian.org/debian/pool/main/libf/libffi/libffi7_3.3-6_arm64.deb
COPY docker/1.0-1/resources/libffi7_3.3-6_arm64.deb /tmp
RUN dpkg -i /tmp/libffi7_3.3-6_arm64.deb

RUN cd /tmp && \
    curl -L --output /tmp/Miniconda3.sh https://repo.anaconda.com/miniconda/Miniconda3-py${CONDA_PY_VERSION}_${MINICONDA_VERSION}-Linux-aarch64.sh && \
    bash /tmp/Miniconda3.sh -bfp /miniconda3 && \
    rm /tmp/Miniconda3.sh

ENV PATH=/miniconda3/bin:${PATH}

# Install MLIO with Apache Arrow integration
# We could install mlio-py from conda, but it comes  with extra support such as image reader that increases image size
# which increases training time. We build from source to minimize the image size.
RUN echo "conda ${CONDA_PKG_VERSION}" >> /miniconda3/conda-meta/pinned && \
    # Conda configuration see https://conda.io/projects/conda/en/latest/configuration.html
   conda config --system --set auto_update_conda false && \
   conda config --system --set show_channel_urls true && \
    echo "python ${PYTHON_VERSION}.*" >> /miniconda3/conda-meta/pinned && \
    conda install -c conda-forge python=${PYTHON_VERSION} && \
    conda install conda=${CONDA_PKG_VERSION} && \
    conda update -y conda && \
    conda install -c conda-forge pyarrow=${PYARROW_VERSION} && \
    cd /tmp  && \
    git clone --branch ${MLIO_VERSION} https://github.com/awslabs/ml-io.git mlio && \
    cd mlio && \
    build-tools/build-dependency build/third-party all && \
    mkdir -p build/release && \
    cd build/release && \
    cmake -GNinja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_PREFIX_PATH="$(pwd)/../third-party" ../.. && \
    cmake --build . && \
    cmake --build . --target install && \
    cmake -DMLIO_INCLUDE_PYTHON_EXTENSION=ON -DPYTHON_EXECUTABLE="/miniconda3/bin/python3" \
        -DMLIO_INCLUDE_ARROW_INTEGRATION=ON ../.. && \
    cmake --build . --target mlio-py && \
    cmake --build . --target mlio-arrow && \
    cd ../../src/mlio-py && \
   python3 setup.py bdist_wheel && \
    python3 -m pip install --upgrade pip && \
    python3 -m pip install dist/*.whl && \
    cp -r /tmp/mlio/build/third-party/lib/libtbb* /usr/local/lib/ && \
    ldconfig && \
    rm -rf /tmp/mlio

# Install awscli
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -r aws awscliv2.zip

# Python won’t try to write .pyc or .pyo files on the import of source modules
# Force stdin, stdout and stderr to be totally unbuffered. Good for logging
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PYTHONIOENCODING=UTF-8 LANG=C.UTF-8 LC_ALL=C.UTF-8

# Install Scikit-Learn
# Scikit-learn 0.20 was the last version to support Python 2.7 and Python 3.4.
# Scikit-learn now requires Python 3.6 or newer.
RUN python -m pip install --no-cache -I scikit-learn==1.5.0
