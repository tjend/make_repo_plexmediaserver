#!/bin/bash
# Check the latest plexmediaserver version vs the latest packaged version.
# If not the same, build a new package, and push to apt repo.

echo 'getting latest releases page'
RELEASES_PAGE="https://plex.tv/api/downloads/1.json"
curl --location --silent "${RELEASES_PAGE}" > releases.json
if [ $? -ne 0 ]; then
  echo "Failed to get the latest releases page!"
  exit 1;
fi

echo 'getting the latest release version number'
LATEST_VERSION_ARMv7=$(cat releases.json | jq '.nas.Synology.version' | cut -d '"' -f 2)
echo "arm={$LATEST_VERSION_ARMv7}"
LATEST_VERSION_AMD64=$(cat releases.json | jq '.computer.Linux.version' | cut -d '"' -f 2)
echo "amd64={$LATEST_VERSION_AMD64}"
if [ "${LATEST_VERSION_ARMv7}" == "" ]; then
  echo "Failed to get the latest release version number!"
  exit 1;
fi
if [ "${LATEST_VERSION_ARMv7}" != "${LATEST_VERSION_AMD64}" ]; then
  echo "ARMv7 version differs from AMD64!"
  exit 1;
fi

echo 'getting the latest urls and checksums'
URL_ARMv7=$(cat releases.json | jq '.nas.Synology.releases[] | select(.label == "ARMv7") | .url' | cut -d '"' -f 2)
CHECKSUM_ARMv7=$(cat releases.json | jq '.nas.Synology.releases[] | select(.label == "ARMv7") | .checksum' | cut -d '"' -f 2)
URL_AMD64=$(cat releases.json | jq '.computer.Linux.releases[] | select(.url | test(".*_amd64.deb"; "i")) | .url' | cut -d '"' -f 2)
CHECKSUM_AMD64=$(cat releases.json | jq '.computer.Linux.releases[] | select(.url | test(".*_amd64.deb"; "i")) | .checksum' | cut -d '"' -f 2)
if [ "${URL_ARMv7}" == "" ] ||
   [ "${CHECKSUM_ARMv7}" == "" ] ||
   [ "${URL_AMD64}" == "" ] ||
   [ "${CHECKSUM_AMD64}" == "" ]; then
  echo "Failed to get the latest urls/checksums!"
  exit 1;
fi

echo 'getting latest package version number'
PACKAGE_VERSION=$(curl --silent "https://tjend.github.io/repo_plexmediaserver/LATEST")
if [ $? -ne 0 ]; then
  echo "Failed to get the latest package version number!"
  exit 1;
fi

echo 'checking if package version matches latest version'
if [ "${LATEST_VERSION_ARMv7}" == "${PACKAGE_VERSION}" ]; then
  echo "Package version matches latest version - ${LATEST_VERSION_ARMv7}."
  exit 0;
fi

echo 'downloading latest files'
curl --silent "${URL_ARMv7}" > latest_armv7.spk
if [ $? -ne 0 ]; then
  echo "Failed to download latest armv7 package!"
  exit 1;
fi
curl --silent "${URL_AMD64}" > latest_amd64.deb
if [ $? -ne 0 ]; then
  echo "Failed to download latest amd64 package!"
  exit 1;
fi

echo 'verifying checksums of downloaded files'
CHECKSUM=$(sha1sum latest_armv7.spk | cut --delimiter=" " --fields="1")
if [ "${CHECKSUM}" != "${CHECKSUM_ARMv7}" ]; then
  echo "checksum of downloaded armv7 file incorrect!"
  echo "wanted=${CHECKSUM_ARMv7} got=${CHECKSUM}"
  ls -al
  exit 1;
fi
CHECKSUM=$(sha1sum latest_amd64.deb | cut --delimiter=" " --fields="1")
if [ "${CHECKSUM}" != "${CHECKSUM_AMD64}" ]; then
  echo "checksum of downloaded amd64 file incorrect!"
  echo "wanted=${CHECKSUM_AMD64} got=${CHECKSUM}"
  ls -al
  exit 1;
fi

echo 'extracting AMD64 package'
dpkg-deb --raw-extract latest_amd64.deb deb
if [ $? -ne 0 ]; then
  echo "Failed to extract AMD64 package!"
  exit 1;
fi

echo 'replacing /usr/lib/plexmediaserver from the AMD64 package with ARMv7 files'
pushd deb/usr/lib/plexmediaserver > /dev/null
if [ $? -ne 0 ]; then
  echo "Failed to change dir to deb/usr/lib/plexmediaserver!"
  exit 1;
fi
rm -rf *
if [ $? -ne 0 ]; then
  echo "Failed to remove files from deb/usr/lib/plexmediaserver!"
  exit 1;
fi
tar xOf ../../../../latest_armv7.spk package.tgz | tar zxf -
if [ $? -ne 0 ]; then
  echo "Failed to replace /usr/lib/plexmediaserver!"
  exit 1;
fi
popd > /dev/null

echo 'modify control file to use armhf architecture'
sed -i 's/amd64/armhf/' deb/DEBIAN/control
if [ $? -ne 0 ]; then
  echo "Failed to update control.tar.gz!"
  exit 1;
fi

echo 'removing old files from md5sums file'
sed -i '/ usr\/lib\/plexmediaserver\//d' deb/DEBIAN/md5sums
if [ $? -ne 0 ]; then
  echo "Failed to remove old files from md5sums file!"
  exit 1;
fi

echo 'adding new files to md5sums file'
pushd deb > /dev/null
find usr/lib/plexmediaserver -type f -exec md5sum {} \; >> DEBIAN/md5sums
if [ $? -ne 0 ]; then
  echo "Failed to add new files to md5sums file!"
  exit 1;
fi
popd > /dev/null

echo 'creating ARMv7 deb file'
fakeroot dpkg-deb --build deb "plexmediaserver_${LATEST_VERSION_ARMv7}_armhf.deb"
if [ $? -ne 0 ]; then
  echo "Failed to create the linux ARMv7 package!"
  exit 1;
fi

echo 'tidy up deb directory'
rm -rf deb

# set restrictive umask so gpg and ssh keys get correct permissions
umask 0077

# set the gpg home dir to be ./gnupg
# explicitly use --homedir with gpg
# explicitly set GNUPGHOME env var with aptly
GNUPGHOME=./gnupg
mkdir -p "${GNUPGHOME}"

echo 'importing apt repo signing key, replacing '_' with newline'
echo "${REPO_PLEXMEDIASERVER_GPG_KEY}" | tr '_' '\n' | gpg --homedir "${GNUPGHOME}" --allow-secret-key-import --import

echo 'configuring gpg to use SHA512'
echo "digest-algo SHA512" >> "${GNUPGHOME}/gpg.conf"

echo "writing apt repo git ssh key, replacing '_' with newline"
echo "${REPO_PLEXMEDIASERVER_SSH_KEY}" | tr '_' '\n' > .id_rsa

echo 'configuring ssh to use our ssh key'
export GIT_SSH_COMMAND='ssh -i .id_rsa -o StrictHostKeyChecking=no'

echo 'cloning the deb repo'
git clone git@github.com:tjend/repo_plexmediaserver.git
if [ $? -ne 0 ]; then
  echo "Failed to clone the deb repo!"
  exit 1;
fi

echo 'initialising aptly'
aptly -config=aptly.conf repo create plexmediaserver
if [ $? -ne 0 ]; then
  echo "Failed to initialise aptly!"
  exit 1;
fi

echo 'adding latest deb file and older deb files to aptly'
aptly -config=aptly.conf repo add plexmediaserver "plexmediaserver_${LATEST_VERSION_ARMv7}_armhf.deb" repo_plexmediaserver/pool/main/p/plexmediaserver/
if [ $? -ne 0 ]; then
  echo "Failed to add latest deb file to aptly!"
  exit 1;
fi

echo 'publishing aptly to static files'
GNUPGHOME="${GNUPGHOME}" aptly -config=aptly.conf -distribution=stable publish repo plexmediaserver
if [ $? -ne 0 ]; then
  echo "Failed to publish aptly to static files!"
  exit 1;
fi

echo 'adding repo files to repo, even if they already exist'
for FILE in $(ls repo_files/); do
  cp --verbose "repo_files/${FILE}" repo_plexmediaserver/
done

echo 'adding latest version file to git repo'
echo "${LATEST_VERSION_ARMv7}" > repo_plexmediaserver/LATEST
if [ $? -ne 0 ]; then
  echo "Failed to add latest version file to git repo!"
  exit 1;
fi

echo "removing deb files from git, as the next cp fails on travis ci complaining deb files are the same(I can't reproduce locally)"
rm -f repo_plexmediaserver/pool/main/p/plexmediaserver/*.deb
if [ $? -ne 0 ]; then
  echo "Failed to remove deb files from git repo!"
  exit 1;
fi


echo 'copying aptly static files to git repo'
cp --recursive --update --verbose aptly/public/* repo_plexmediaserver/
if [ $? -ne 0 ]; then
  echo "Failed to copy aptly static files to git repo!"
  exit 1;
fi

echo 'pushing the updated deb repo'
export GIT_SSH_COMMAND='ssh -i ../.id_rsa -o StrictHostKeyChecking=no'
pushd repo_plexmediaserver && git add . && HOME=../gitconfig git commit -m "Add plexmediaserver ${LATEST_VERSION_ARMv7}" && git push --set-upstream origin master
if [ $? -ne 0 ]; then
  echo "Failed to push the updated deb repo!"
  exit 1;
fi
popd

echo 'cleaning up'
rm -rf gnupg .id_rsa

echo 'Script finished successfully!'
exit 0
