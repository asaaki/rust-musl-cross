FROM quay.io/pypa/manylinux2014_x86_64:latest

# The Rust toolchain to use when building our image
ARG TOOLCHAIN=stable
ARG TARGET=x86_64-unknown-linux-musl
ARG OPENSSL_ARCH=linux-x86_64

ENV RUST_MUSL_CROSS_TARGET=$TARGET

# Make sure we have basic dev tools for building C libraries.  Our goal
# here is to support the musl-libc builds and Cargo builds needed for a
# large selection of the most popular crates.
#
RUN yum install -y sudo

# Install cross-signed Let's Encrypt R3 CA certificate
ADD lets-encrypt-r3-cross-signed.crt /etc/pki/ca-trust/source/anchors/
RUN update-ca-trust

ADD config.mak /tmp/config.mak
RUN cd /tmp && \
    curl -Lsq -o musl-cross-make.zip https://github.com/richfelker/musl-cross-make/archive/v0.9.8.zip && \
    unzip -q musl-cross-make.zip && \
    rm musl-cross-make.zip && \
    mv musl-cross-make-0.9.8 musl-cross-make && \
    cp /tmp/config.mak /tmp/musl-cross-make/config.mak && \
    cd /tmp/musl-cross-make && \
    TARGET=$TARGET make -j 4 install > /tmp/musl-cross-make.log && \
    ln -s /usr/local/musl/bin/$TARGET-strip /usr/local/musl/bin/musl-strip && \
    cd /tmp && \
    rm -rf /tmp/musl-cross-make /tmp/musl-cross-make.log

RUN mkdir -p /home/rust/libs /home/rust/src

# Set up our path with all our binary directories, including those for the
# musl-gcc toolchain and for our Rust toolchain.
ENV PATH=/root/.cargo/bin:/usr/local/musl/bin:/opt/rh/devtoolset-9/root/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV TARGET_CC=$TARGET-gcc
ENV TARGET_CXX=$TARGET-g++
ENV TARGET_C_INCLUDE_PATH=/usr/local/musl/$TARGET/include/

# Install our Rust toolchain and the `musl` target.  We patch the
# command-line we pass to the installer so that it won't attempt to
# interact with the user or fool around with TTYs.  We also set the default
# `--target` to musl so that our users don't need to keep overriding it
# manually.
# Chmod 755 is set for root directory to allow access execute binaries in /root/.cargo/bin (azure piplines create own user).
RUN chmod 755 /root/ && \
    curl https://sh.rustup.rs -sqSf | \
    sh -s -- -y --default-toolchain $TOOLCHAIN && \
    rustup target add $TARGET && \
    rm -rf /root/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/share/
RUN printf "[build]\ntarget = \"$TARGET\"\n\n[target.$TARGET]\nlinker = \"$TARGET-gcc\"\n" > /root/.cargo/config && \
    cat /root/.cargo/config

# We'll build our libraries in subdirectories of /home/rust/libs.  Please
# clean up when you're done.
WORKDIR /home/rust/libs

# Build a static library version of OpenSSL using musl-libc.  This is
# needed by the popular Rust `hyper` crate.
RUN export CC=$TARGET_CC && \
    export C_INCLUDE_PATH=$TARGET_C_INCLUDE_PATH && \
    echo "Building zlib" && \
    VERS=1.2.11 && \
    CHECKSUM=c3e5e9fdd5004dcb542feda5ee4f0ff0744628baf8ed2dd5d66f8ca1197cb1a1 && \
    cd /home/rust/libs && \
    curl -sqLO https://zlib.net/zlib-$VERS.tar.gz && \
    echo "$CHECKSUM zlib-$VERS.tar.gz" > checksums.txt && \
    sha256sum -c checksums.txt && \
    tar xzf zlib-$VERS.tar.gz && cd zlib-$VERS && \
    ./configure --static --archs="-fPIC" --prefix=/usr/local/musl/$TARGET && \
    make && make install && \
    cd .. && rm -rf zlib-$VERS.tar.gz zlib-$VERS checksums.txt && \
    echo "Building OpenSSL" && \
    VERS=1.0.2q && \
    CHECKSUM=5744cfcbcec2b1b48629f7354203bc1e5e9b5466998bbccc5b5fcde3b18eb684 && \
    curl -sqO https://www.openssl.org/source/openssl-$VERS.tar.gz && \
    echo "$CHECKSUM openssl-$VERS.tar.gz" > checksums.txt && \
    sha256sum -c checksums.txt && \
    tar xzf openssl-$VERS.tar.gz && cd openssl-$VERS && \
    ./Configure $OPENSSL_ARCH -fPIC --prefix=/usr/local/musl/$TARGET && \
    make depend && \
    make && make install && \
    cd .. && rm -rf openssl-$VERS.tar.gz openssl-$VERS checksums.txt

ENV OPENSSL_DIR=/usr/local/musl/$TARGET/ \
    OPENSSL_INCLUDE_DIR=/usr/local/musl/$TARGET/include/ \
    DEP_OPENSSL_INCLUDE=/usr/local/musl/$TARGET/include/ \
    OPENSSL_LIB_DIR=/usr/local/musl/$TARGET/lib/ \
    OPENSSL_STATIC=1

# Expect our source code to live in /home/rust/src
WORKDIR /home/rust/src
