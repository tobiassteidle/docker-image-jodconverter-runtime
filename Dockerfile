ARG TARGET_BASE_IMAGE=debian:bookworm
ARG JAVA_VERSION=21

############ JRESOURCE ############
FROM eclipse-temurin:${JAVA_VERSION}-jdk-noble as jresource
ENV JAVA_MODULES=java.base,java.compiler,java.datatransfer,java.desktop,java.instrument,java.logging,java.management,java.management.rmi,java.naming,java.net.http,java.prefs,java.rmi,java.scripting,java.se,java.security.jgss,java.security.sasl,java.smartcardio,java.sql,java.sql.rowset,java.transaction.xa,java.xml,java.xml.crypto,jdk.accessibility,jdk.charsets,jdk.crypto.cryptoki,jdk.crypto.ec,jdk.dynalink,jdk.httpserver,jdk.incubator.vector,jdk.internal.vm.ci,jdk.internal.vm.compiler,jdk.internal.vm.compiler.management,jdk.jdwp.agent,jdk.jfr,jdk.jsobject,jdk.localedata,jdk.management,jdk.management.agent,jdk.management.jfr,jdk.naming.dns,jdk.naming.rmi,jdk.net,jdk.nio.mapmode,jdk.sctp,jdk.security.auth,jdk.security.jgss,jdk.unsupported,jdk.xml.dom,jdk.zipfs

RUN $JAVA_HOME/bin/jlink \
    --add-modules $JAVA_MODULES \
    --strip-debug \
    --no-man-pages \
    --no-header-files \
    --compress=2 \
    --output /jre

############ JRE ############
ARG TARGET_BASE_IMAGE

FROM $TARGET_BASE_IMAGE as jre

ARG JAVA_VERSION

ENV JAVA_HOME=/opt/java/openjdk
ENV PATH "${JAVA_HOME}/bin:${PATH}"

# expose our GOSU user
ENV NONPRIVUSER=jodconverter
ENV NONPRIVGROUP=jodconverter

# Set default characterset encoding to UTF-8
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

COPY --from=jresource /jre $JAVA_HOME

# using backports for libreoffice 24.x (bookworm has 7.x)
RUN echo 'deb http://deb.debian.org/debian bookworm-backports main' > /etc/apt/sources.list.d/backports.list \
  && apt-get update && apt-get -y install \
  apt-transport-https locales-all libpng16-16 libxinerama1 libgl1-mesa-glx libfontconfig1 libfreetype6 libxrender1 \
  libxcb-shm0 libxcb-render0 adduser cpio findutils gosu \
  # wget + ca-certificates needed to fetch the Bouncy Castle 1.86 jars (see CVE remediation below)
  wget ca-certificates \
  # procps needed for us finding the libreoffice process, see https://github.com/sbraconnier/jodconverter/issues/127#issuecomment-463668183
  procps \
  # using backports for libreoffice 24.x (bookworm has 7.x)
  && apt-get -y install -t bookworm-backports libreoffice libreoffice-base libreoffice-common libreoffice-base-core \
  && apt-get update && apt-get purge -y \
    firebird3.0-common \
    firebird3.0-common-doc \
    firebird3.0-server-core \
    firebird3.0-utils \
  && apt-get autoremove -y \
  && apt-get clean \
  # --- CVE-2026-71885: replace Debian Bouncy Castle 1.72 (transitive LibreOffice dep) with upstream 1.86 ---
  # The scan reads the dpkg database, so we must raise the recorded package version, not just swap the jar.
  # Purging the packages is not an option: libitext-java (and other LibreOffice deps) depend on them, which
  # breaks later apt operations. Instead we rebuild each libbc*-java as a minimal .deb at version 1.86-1 that
  # ships the real upstream jar, then install it as an UPGRADE over 1.72-2 - this keeps all dependencies
  # satisfied, bumps the dpkg version so the scan is clean, and provides functional Bouncy Castle 1.86.
  && BC_VERSION=1.86 \
  && BC_BASE=https://repo1.maven.org/maven2/org/bouncycastle \
  && mkdir -p /tmp/bcbuild \
  && for pair in bcprov:libbcprov-java bcpkix:libbcpkix-java bcmail:libbcmail-java bcutil:libbcutil-java; do \
       art="${pair%%:*}"; pkg="${pair##*:}"; \
       url="$BC_BASE/${art}-jdk18on/${BC_VERSION}/${art}-jdk18on-${BC_VERSION}.jar"; \
       root="/tmp/bcbuild/$pkg"; \
       mkdir -p "$root/DEBIAN" "$root/usr/share/java"; \
       wget -q "$url"          -O "$root/usr/share/java/${art}.jar" && \
       wget -q "${url}.sha256" -O "/tmp/${art}.sha256" && \
       echo "$(cat /tmp/${art}.sha256)  $root/usr/share/java/${art}.jar" | sha256sum -c - && \
       printf 'Package: %s\nVersion: %s-1\nArchitecture: all\nMaintainer: jodconverter base image\nSection: java\nPriority: optional\nDescription: Bouncy Castle %s (upstream jar, CVE-2026-71885 remediation)\n' "$pkg" "$BC_VERSION" "$BC_VERSION" > "$root/DEBIAN/control" && \
       dpkg-deb --build --root-owner-group "$root" "/tmp/${pkg}.deb" || exit 1; \
     done \
  && dpkg -i /tmp/libbcprov-java.deb /tmp/libbcpkix-java.deb /tmp/libbcmail-java.deb /tmp/libbcutil-java.deb \
  && rm -rf /tmp/bcbuild /tmp/*.deb /tmp/*.sha256 \
  && groupadd $NONPRIVGROUP \
  && useradd -m $NONPRIVUSER -g $NONPRIVGROUP \
  && rm -rf /var/lib/apt/lists/*

# create font-cache for our gosu user
USER jodconverter
RUN fc-cache -fr
USER root

# We do not need a CMD nor ENTRYPOINT, since we are not going to run anything. This is just the libreoffice runtime for \
# running jodconverter - the app is packaged in a different repo

############ jdk ############

FROM jre as jdk
ARG JAVA_VERSION

# unset old JAVA_HOME (matches JRE) since we use a JDK here
ENV JAVA_HOME ""

# see https://adoptium.net/installation/linux/
RUN unset JAVA_HOME \
    && apt update && apt install -y wget apt-transport-https \
    && mkdir -p /etc/apt/keyrings \
    && wget -O - https://packages.adoptium.net/artifactory/api/gpg/key/public | tee /etc/apt/keyrings/adoptium.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/adoptium.asc] https://packages.adoptium.net/artifactory/deb $(awk -F= '/^VERSION_CODENAME/{print$2}' /etc/os-release) main" | tee /etc/apt/sources.list.d/adoptium.list \
    && apt update \
    && apt install -y temurin-${JAVA_VERSION}-jdk \
    && apt autoclean -y && apt clean -y \
    # rm jdk
    && rm -fr /opt/java/openjdk

