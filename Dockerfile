FROM ubuntu:24.04 AS builder

# ──────────────────────────────────────────────────────────────────────────
# STAGE 1 — BUILDER : compile WRF + WPS avec Intel oneAPI
# Ce stage est volumineux (~10 Go) mais disparaît de l'image finale.
# ──────────────────────────────────────────────────────────────────────────

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

# ── 1. Dépendances système ──────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        m4 \
        libpng-dev \
        zlib1g-dev \
        libcurl4-openssl-dev \
        wget \
        curl \
        ca-certificates \
        gnupg \
        git \
        cmake \
        libtirpc-dev \
        gfortran \
        autoconf \
        automake \
        libtool \
        tcsh \
        csh \
        perl \
        python3 \
        python3-pip \
        && rm -rf /var/lib/apt/lists/*

# ── 2. Intel oneAPI (compilateurs + MPI) ────────────────────────────────────
RUN curl -fsSL https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
        | gpg --dearmor -o /usr/share/keyrings/oneapi-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" \
        > /etc/apt/sources.list.d/oneAPI.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        intel-oneapi-compiler-fortran \
        intel-oneapi-compiler-dpcpp-cpp \
        intel-oneapi-mpi \
        intel-oneapi-mpi-devel \
    && rm -rf /var/lib/apt/lists/*

# ── 3. Variables d'environnement ────────────────────────────────────────────
ENV WRF_LIBS=/opt/wrf-intel/libs
ENV WRF_SRC=/opt/wrf-intel/src
ENV CC=icx
ENV CXX=icpx
ENV FC=ifx
ENV F77=ifx
ENV F90=ifx
ENV I_MPI_CC=icx
ENV I_MPI_CXX=icpx
ENV I_MPI_FC=ifx
ENV I_MPI_F77=ifx
ENV I_MPI_F90=ifx
ENV JASPER=$WRF_LIBS
ENV JASPERINC=$WRF_LIBS/include
ENV JASPERLIB=$WRF_LIBS/lib
ENV NETCDF=$WRF_LIBS
ENV HDF5=$WRF_LIBS
ENV LDFLAGS="-L$WRF_LIBS/lib"
ENV CPPFLAGS="-I$WRF_LIBS/include -I/usr/include/tirpc"
ENV LD_LIBRARY_PATH="$WRF_LIBS/lib:/opt/intel/oneapi/mpi/latest/lib"
ENV PATH="/opt/intel/oneapi/mpi/latest/bin:$PATH"

# Active l'environnement Intel pour tous les RUN suivants
SHELL ["/bin/bash", "-c", "-l"]
RUN echo "source /opt/intel/oneapi/setvars.sh > /dev/null 2>&1" >> /etc/bash.bashrc

RUN mkdir -p $WRF_LIBS $WRF_SRC

# ── 4. JasPer 3.0.6 (avec symboles publics jpc_decode/encode) ─────────────
RUN source /opt/intel/oneapi/setvars.sh && \
    cd $WRF_SRC && \
    wget -q https://github.com/jasper-software/jasper/releases/download/version-3.0.6/jasper-3.0.6.tar.gz && \
    tar xf jasper-3.0.6.tar.gz && \
    mkdir jasper-build && cd jasper-build && \
    cmake $WRF_SRC/jasper-3.0.6 \
        -DCMAKE_INSTALL_PREFIX=$WRF_LIBS \
        -DCMAKE_C_COMPILER=$(which icx) \
        -DCMAKE_MODULE_PATH=$WRF_SRC/jasper-3.0.6/build/cmake/modules \
        -DJAS_ENABLE_SHARED=ON \
        -DJAS_ENABLE_HIDDEN=OFF \
        -DJAS_ENABLE_OPENGL=OFF \
        -DJAS_ENABLE_DOC=OFF \
        -DJAS_ENABLE_PROGRAMS=OFF && \
    make -j$(nproc) && make install

# ── 5. zlib 1.3.2 ────────────────────────────────────────────────────────
RUN source /opt/intel/oneapi/setvars.sh && \
    cd $WRF_SRC && \
    wget -q https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz && \
    tar xf zlib-1.3.2.tar.gz && cd zlib-1.3.2 && \
    ./configure --prefix=$WRF_LIBS && \
    make -j$(nproc) && make install

# ── 6. libpng 1.2.59 ─────────────────────────────────────────────────────
RUN source /opt/intel/oneapi/setvars.sh && \
    cd $WRF_SRC && \
    wget -q https://sourceforge.net/projects/libpng/files/libpng12/1.2.59/libpng-1.2.59.tar.gz && \
    tar xf libpng-1.2.59.tar.gz && cd libpng-1.2.59 && \
    ./configure --prefix=$WRF_LIBS CC=icx && \
    make -j$(nproc) && make install

# ── 7. HDF5 1.14.6 ───────────────────────────────────────────────────────
RUN source /opt/intel/oneapi/setvars.sh && \
    cd $WRF_SRC && \
    wget -q https://github.com/HDFGroup/hdf5/archive/refs/tags/hdf5-1.14.6.tar.gz -O hdf5-1.14.6.tar.gz && \
    tar xf hdf5-1.14.6.tar.gz && cd hdf5-hdf5-1.14.6 && \
    ./configure --prefix=$WRF_LIBS \
        --with-zlib=$WRF_LIBS \
        --enable-fortran \
        --enable-shared \
        FC=ifx CC=icx && \
    make -j$(nproc) && make install

# ── 8. NetCDF-C 4.9.2 ────────────────────────────────────────────────────
RUN source /opt/intel/oneapi/setvars.sh && \
    cd $WRF_SRC && \
    wget -q https://github.com/Unidata/netcdf-c/archive/refs/tags/v4.9.2.tar.gz && \
    tar xf v4.9.2.tar.gz && cd netcdf-c-4.9.2 && \
    CPPFLAGS="-I$WRF_LIBS/include" \
    LDFLAGS="-L$WRF_LIBS/lib" \
    ./configure --prefix=$WRF_LIBS \
        --enable-netcdf4 \
        --disable-dap \
        --disable-libxml2 \
        CC=icx && \
    make -j$(nproc) && make install

# ── 9. NetCDF-Fortran 4.6.1 ──────────────────────────────────────────────
RUN source /opt/intel/oneapi/setvars.sh && \
    cd $WRF_SRC && \
    wget -q https://github.com/Unidata/netcdf-fortran/archive/refs/tags/v4.6.1.tar.gz && \
    tar xf v4.6.1.tar.gz && cd netcdf-fortran-4.6.1 && \
    CPPFLAGS="-I$WRF_LIBS/include" \
    LDFLAGS="-L$WRF_LIBS/lib" \
    LD_LIBRARY_PATH="$WRF_LIBS/lib:$LD_LIBRARY_PATH" \
    ./configure --prefix=$WRF_LIBS FC=ifx CC=icx && \
    make -j$(nproc) && make install

# ── 10. Clone WRF + patches ──────────────────────────────────────────────
# IMPORTANT : LD_LIBRARY_PATH (Intel) casse git -> on le vide pour cette étape
SHELL ["/bin/bash", "-c"]
RUN env LD_LIBRARY_PATH= bash -c '\
    cd /opt/wrf-intel && \
    git clone --depth 1 -b release-v4.7.1 https://github.com/wrf-model/WRF.git && \
    cd WRF && \
    sed -i "s/\$I_really_want_to_output_grib2_from_WRF = \"FALSE\"/\$I_really_want_to_output_grib2_from_WRF = \"TRUE\"/" arch/Config.pl && \
    sed -i "s/image\.inmem_=1;//" external/io_grib2/g2lib/enc_jpeg2000.c \
    '
SHELL ["/bin/bash", "-c", "-l"]

# ── 11. Compiler g2lib manuellement et l'intégrer à libio_grib2 ─────────
RUN source /opt/intel/oneapi/setvars.sh && \
    cd /opt/wrf-intel/WRF/external/io_grib2/g2lib && \
    (make FC=ifx CC=icx \
        CPP="/lib/cpp -P -traditional-cpp" \
        FIXED="-fixed" \
        FFLAGS="-O3" \
        FCFLAGS="-O3" \
        CFLAGS="-O3 -I$WRF_LIBS/include" || true) && \
    ar cr libg2.a *.o && \
    cd /opt/wrf-intel/WRF/external/io_grib2 && \
    ar -x g2lib/libg2.a && \
    ar ru libio_grib2.a *.o && \
    nm libio_grib2.a | grep "T getgb2_"

# ── 12. Configurer et compiler WRF (dmpar, Intel ifx/icx) ────────────────
# Option 78 = INTEL (ifx/icx) oneAPI LLVM dmpar ; nesting = 1 (basic)
RUN source /opt/intel/oneapi/setvars.sh && \
    cd /opt/wrf-intel/WRF && \
    export CPPFLAGS="-I$WRF_LIBS/include -I/usr/include/tirpc" && \
    (echo 78; echo 1) | ./configure && \
    sed -i 's/DM_FC[[:space:]]*=[[:space:]]*mpif90 -f90=\$(SFC)/DM_FC           =       mpiifx/' configure.wrf && \
    sed -i 's/DM_CC[[:space:]]*=[[:space:]]*mpicc -cc=\$(SCC)/DM_CC           =       mpiicc/' configure.wrf && \
    cp share/landread.c.dist share/landread.c

RUN source /opt/intel/oneapi/setvars.sh && \
    cd /opt/wrf-intel/WRF && \
    ./compile em_real 2>&1 | tee compile.log | tail -100 && \
    ls -la main/*.exe

# ── 13. Clone et compiler WPS ─────────────────────────────────────────────
SHELL ["/bin/bash", "-c"]
RUN env LD_LIBRARY_PATH= bash -c '\
    cd /opt/wrf-intel && \
    git clone --depth 1 https://github.com/wrf-model/WPS.git \
    '
SHELL ["/bin/bash", "-c", "-l"]

# Patch connu : glevel1/glevel2 déclarés "real" dans rd_grib2.F provoquent une
# comparaison flottante imprécise (.eq.) avec les niveaux entiers du Vtable,
# ce qui fait échouer la détection des niveaux de sol (NUM_METGRID_SOIL_LEVELS=0)
# avec Intel oneAPI récent. Fix : déclarer ces variables en "integer".
# Réf : https://forum.mmm.ucar.edu/threads/subsoil-level-not-found-in-ungrib-file.21884/
RUN sed -i \
    's/real[[:space:]]*::[[:space:]]*glevel1, glevel2/integer :: glevel1, glevel2/' \
    /opt/wrf-intel/WPS/ungrib/src/rd_grib2.F && \
    grep -n "glevel1, glevel2" /opt/wrf-intel/WPS/ungrib/src/rd_grib2.F

RUN source /opt/intel/oneapi/setvars.sh && \
    cd /opt/wrf-intel/WPS && \
    export WRF_DIR=/opt/wrf-intel/WRF && \
    (echo 19) | ./configure && \
    ./compile 2>&1 | tee compile.log | tail -100 && \
    ls -la *.exe

# ── 14. Étiquette les répertoires runtime utiles pour le stage suivant ───
# (rien à faire ici — le COPY --from=builder du stage 2 cible directement
#  les chemins /opt/wrf-intel/... et /opt/intel/oneapi/.../lib)


# ══════════════════════════════════════════════════════════════════════════
# STAGE 2 — RUNTIME : image finale légère
# Ne contient ni compilateurs, ni sources, ni fichiers .o/.mod
# ══════════════════════════════════════════════════════════════════════════
FROM ubuntu:24.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive

# ── Dépendances runtime uniquement (pas de -dev, pas de build-essential) ──
RUN apt-get update && apt-get install -y --no-install-recommends \
        libcurl4 \
        libssl3 \
        libstdc++6 \
        libgomp1 \
        ca-certificates \
        tcsh \
        perl \
        python3 \
        python3-pip \
        less \
        vim \
        nano \
        wget \
        curl \
        netcdf-bin \
        ncview \
        nco \
        cdo \
        eog \
        tree \
        && rm -rf /var/lib/apt/lists/*

# ── Copier nos bibliothèques compilées (NetCDF, HDF5, JasPer, libpng, zlib) ──
COPY --from=builder /opt/wrf-intel/libs/lib /opt/wrf-intel/libs/lib

# ── Copier le runtime Intel (compilateur + MPI), sans le compilateur lui-même ──
# On ne copie QUE les .so listés par ldd, pas tout /opt/intel/oneapi
RUN mkdir -p /opt/intel/oneapi/compiler/lib /opt/intel/oneapi/mpi/lib
COPY --from=builder /opt/intel/oneapi/compiler/2026.0/lib/libimf.so       /opt/intel/oneapi/compiler/lib/
COPY --from=builder /opt/intel/oneapi/compiler/2026.0/lib/libifport.so.5  /opt/intel/oneapi/compiler/lib/
COPY --from=builder /opt/intel/oneapi/compiler/2026.0/lib/libifcoremt.so.5 /opt/intel/oneapi/compiler/lib/
COPY --from=builder /opt/intel/oneapi/compiler/2026.0/lib/libsvml.so      /opt/intel/oneapi/compiler/lib/
COPY --from=builder /opt/intel/oneapi/compiler/2026.0/lib/libintlc.so.5   /opt/intel/oneapi/compiler/lib/
COPY --from=builder /opt/intel/oneapi/compiler/2026.0/lib/libirng.so      /opt/intel/oneapi/compiler/lib/
COPY --from=builder /opt/intel/oneapi/mpi/2021.18/lib/libmpifort.so.12    /opt/intel/oneapi/mpi/lib/
COPY --from=builder /opt/intel/oneapi/mpi/2021.18/lib/libmpi.so.12        /opt/intel/oneapi/mpi/lib/
# mpirun et ses dépendances internes (hydra, etc.) — copie du bin complet
COPY --from=builder /opt/intel/oneapi/mpi/2021.18/bin                    /opt/intel/oneapi/mpi/bin
COPY --from=builder /opt/intel/oneapi/mpi/2021.18/opt                    /opt/intel/oneapi/mpi/opt
COPY --from=builder /opt/intel/oneapi/mpi/2021.18/etc                    /opt/intel/oneapi/mpi/etc

# ── Copier les exécutables WRF et fichiers de run nécessaires ──
COPY --from=builder /opt/wrf-intel/WRF/main/wrf.exe   /opt/wrf-intel/WRF/main/
COPY --from=builder /opt/wrf-intel/WRF/main/real.exe  /opt/wrf-intel/WRF/main/
COPY --from=builder /opt/wrf-intel/WRF/main/ndown.exe /opt/wrf-intel/WRF/main/
COPY --from=builder /opt/wrf-intel/WRF/main/tc.exe    /opt/wrf-intel/WRF/main/
COPY --from=builder /opt/wrf-intel/WRF/run            /opt/wrf-intel/WRF/run
# MPTABLE.TBL est un lien symbolique cassé dans run/ — on copie la vraie source
COPY --from=builder /opt/wrf-intel/WRF/phys/noahmp/parameters/MPTABLE.TBL \
                    /opt/wrf-intel/WRF/run/MPTABLE.TBL

# ── Copier les exécutables WPS et tables associées ──
COPY --from=builder /opt/wrf-intel/WPS/geogrid.exe         /opt/wrf-intel/WPS/
COPY --from=builder /opt/wrf-intel/WPS/ungrib.exe           /opt/wrf-intel/WPS/
COPY --from=builder /opt/wrf-intel/WPS/metgrid.exe          /opt/wrf-intel/WPS/
COPY --from=builder /opt/wrf-intel/WPS/geogrid/src/geogrid.exe /opt/wrf-intel/WPS/geogrid/src/
COPY --from=builder /opt/wrf-intel/WPS/ungrib/src/ungrib.exe   /opt/wrf-intel/WPS/ungrib/src/
COPY --from=builder /opt/wrf-intel/WPS/metgrid/src/metgrid.exe /opt/wrf-intel/WPS/metgrid/src/
COPY --from=builder /opt/wrf-intel/WPS/geogrid/GEOGRID.TBL.ARW /opt/wrf-intel/WPS/geogrid/
COPY --from=builder /opt/wrf-intel/WPS/metgrid/METGRID.TBL.ARW /opt/wrf-intel/WPS/metgrid/
RUN ln -sf GEOGRID.TBL.ARW /opt/wrf-intel/WPS/geogrid/GEOGRID.TBL && \
    ln -sf METGRID.TBL.ARW /opt/wrf-intel/WPS/metgrid/METGRID.TBL
COPY --from=builder /opt/wrf-intel/WPS/ungrib/Variable_Tables  /opt/wrf-intel/WPS/ungrib/Variable_Tables
COPY --from=builder /opt/wrf-intel/WPS/link_grib.csh           /opt/wrf-intel/WPS/
COPY --from=builder /opt/wrf-intel/WPS/util/src /opt/wrf-intel/WPS/util/src

# ── Miniforge + wrf-python ─────────────────────────────────────────────────
# Miniforge (conda-forge uniquement, sans TOS Anaconda)
# wrf-python 1.3.x nécessite Python 3.11 (numpy.distutils supprimé en 3.12/3.13)
RUN wget -q https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh \
        -O /tmp/miniforge.sh && \
    bash /tmp/miniforge.sh -b -p /opt/miniforge3 && \
    rm /tmp/miniforge.sh

# Créer l'environnement wrf-py avec Python 3.11 explicitement
RUN /opt/miniforge3/bin/conda create -n wrf-py python=3.11 -y -c conda-forge && \
    /opt/miniforge3/bin/conda install -n wrf-py -y -c conda-forge \
        wrf-python xarray netcdf4 plotly numpy scipy matplotlib cartopy && \
    /opt/miniforge3/bin/conda clean -afy

# Ajouter l'environnement wrf-py au PATH
ENV PATH="/opt/miniforge3/envs/wrf-py/bin:/opt/miniforge3/bin:$PATH"


# ── Variables d'environnement runtime ──
ENV LD_LIBRARY_PATH="/opt/wrf-intel/libs/lib:/opt/intel/oneapi/compiler/lib:/opt/intel/oneapi/mpi/lib"
ENV PATH="/opt/intel/oneapi/mpi/bin:/opt/wrf-intel/WRF/main:/opt/wrf-intel/WPS:$PATH"
ENV WRF_DIR=/opt/wrf-intel/WRF
ENV WPS_DIR=/opt/wrf-intel/WPS

# ── Stack illimitée : requis par ungrib.exe/wrf.exe (segfault sinon) ──
# ulimit ne peut pas être fixé via ENV ; on l'ajoute au profil shell
# et on fournit un entrypoint qui l'applique aussi pour les appels directs.
RUN echo "ulimit -s unlimited" >> /etc/bash.bashrc && \
    echo "* soft stack unlimited" >> /etc/security/limits.conf && \
    echo "* hard stack unlimited" >> /etc/security/limits.conf

COPY <<'ENTRYPOINT_EOF' /usr/local/bin/docker-entrypoint.sh
#!/bin/bash
ulimit -s unlimited
exec "$@"
ENTRYPOINT_EOF
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /opt/wrf-intel/WRF/run

# NOTE : ulimit dans le conteneur reste plafonné par l'hôte. Si un segfault
# de stack revient malgré l'entrypoint, lancer avec :
#   docker run --ulimit stack=-1 ...
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/bin/bash"]
