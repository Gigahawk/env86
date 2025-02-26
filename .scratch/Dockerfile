FROM i386/alpine:3.18.6

ENV KERNEL=lts
ENV HOSTNAME=localhost
ENV PASSWORD='root'

RUN apk add openrc \ 
            alpine-base \
            agetty \
            alpine-conf

# Install mkinitfs from edge (todo: remove this when 3.19+ has worked properly with 9pfs)
RUN apk add mkinitfs --no-cache --allow-untrusted --repository https://dl-cdn.alpinelinux.org/alpine/edge/main/ 

RUN if [ "$KERNEL" == "lts" ]; then \
    apk add linux-lts \
            linux-firmware-none \
            linux-firmware-sb16; \
else \
    apk add linux-$KERNEL; \
fi


# Adding networking.sh script (works only on lts kernel yet)
RUN if [ "$KERNEL" == "lts" ]; then \ 
    echo -e "echo '127.0.0.1 localhost' >> /etc/hosts && rmmod ne2k-pci && modprobe ne2k-pci\nhwclock -s\nsetup-interfaces -a -r" > /root/networking.sh && \ 
    chmod +x /root/networking.sh; \ 
fi

# Install nix installer deps
RUN apk add curl xz sudo bash shadow

# Set bash as default shell
RUN rm /bin/sh && ln -s /bin/bash /bin/sh

# Hack to workaround installer crash
# https://github.com/NixOS/nix/issues/1559#issuecomment-328095475
RUN addgroup -g 30000 -S nixbld; \
for i in $(seq 1 30); do \
  adduser -S -D -h /var/empty -g "Nix build user $i" -u $((30000 + $i)) -G nixbld nixbld$i ; \
done

# Download nix install script
RUN curl -L https://nixos.org/nix/install > nix-install.sh && chmod +x nix-install.sh

# HACK: Running this inside docker build results in x86_64 nix being installed,
# force i386
RUN sed -i 's|$(uname -m)|i686|' nix-install.sh

# Install nix
RUN bash nix-install.sh --no-daemon

# Add to path
RUN echo "export USER=root; if  [ -e /root/.nix-profile/etc/profile.d/nix.sh ]; then . /root/.nix-profile/etc/profile.d/nix.sh; fi" >> /root/.bashrc

# Enable flakes
RUN mkdir -p /root/.config/nix/ && echo "experimental-features = nix-command flakes" > /root/.config/nix/nix.conf


# Add project deps
RUN apk add git

RUN cd && \
git clone https://github.com/Gigahawk/ps2str-nix.git && \
cd ps2str-nix && \
git checkout 700b1d9ef971186a9d5a391fc602e654b373862f

RUN bash -c ". /root/.bashrc; cd /root/ps2str-nix && nix flake archive"



RUN sed -i 's/getty 38400 tty1/agetty --autologin root tty1 linux/' /etc/inittab
RUN echo 'ttyS0::once:/sbin/agetty --autologin root -s ttyS0 115200 vt100' >> /etc/inittab 
RUN echo "root:$PASSWORD" | chpasswd

# https://wiki.alpinelinux.org/wiki/Alpine_Linux_in_a_chroot#Preparing_init_services
RUN for i in devfs dmesg mdev hwdrivers; do rc-update add $i sysinit; done
RUN for i in hwclock modules sysctl hostname bootmisc; do rc-update add $i boot; done
RUN rc-update add killprocs shutdown

# Generate initramfs with 9p modules
RUN mkinitfs -F "ata base ide scsi virtio ext4 9p" $(cat /usr/share/kernel/$KERNEL/kernel.release)