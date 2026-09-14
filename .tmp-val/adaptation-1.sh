dpkg --add-architecture arm64
apt-get update -qq
apt-get install -y -qq --allow-downgrades \
  devscripts equivs crossbuild-essential-arm64 debhelper fakeroot
