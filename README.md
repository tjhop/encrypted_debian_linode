# Encrypted Debian Debootstrap script

## Description
Build Debian 9 using BTRFS on encrypted disks on a [Linode server](https://www.linode.com/).

## Status
It works and does everything I want right now:
- Builds Debian on encrypted disks
- Uses BTRFS by default with simple subvolume setup (root and snapshots, no separate home subvolumes or anything)
- Builds a minimal system and only installs what I need/want.
- Provides a (IMO) good base/clean slate to work from. The remainder of the system configuration is purposefully left for other config scripts or system configuration services (I'm using salt now).

## Using the script
This requires some manual prep because it builds the encrypted disks from rescue mode. Here's my current workflow:

Linode creation and prep:
- Create new Linode at desired size/location
- Create 3 disks and format them as follows:
  - /dev/sda
    - label: boot
    - type: unformatted/RAW
    - size: 256 MB
  - /dev/sdb
    - label: swap
    - type: unformatted/RAW
    - size: 256 MB
  - /dev/sdc
    - label: Debian (or whatever you want to name your system disk)
    - type: unformatted/RAW
    - size: <remaining disk space>
- Create configuration profile as follows:
  - Kernel: GRUB2
  - Disks: specify /dev/sda, /dev/sdb, and /dev/sdc as specified above ^
  - Disable all boot helpers (at the bottom)
- Reboot the Linode into rescue mode (and specify /dev/sda, /dev/sdb, and /dev/sdc as specified above ^)

Once the Linode is in rescue mode:
- Connect to the Linode with Lish and set password and enable SSH:

  ```
  passwd
  service ssh start
  ```
- Get the `debian_install.sh` script onto the rescue system and executable somehow. `Git clone`, `scp`, `vim`, etc.
- Run the `debian_install.sh` script with a syntax similar to this:

  `./debian_install 2>&1 | tee debian.log`

  This will allow you to capture all output from the script into a log file that can be `scp`'d off if something breaks catastrophically.

Once in the script and running:
- The script is interactive and will prompt for various settings, including:
  - encryption passwords for LUKS
  - username/passwords/SSH key
  - IPv4/IPv6 addresses for the newly created Linode to set static networking
  - Optional private IP config (*note* this needs a private IP address already assigned to the Linode)
- You'll get to a point where it'll say:
  > ~ Alright, starting to do stuff now. Come back in 5 mins.

  Follow it.
- When the script is done, it'll say so. `scp` the log file to your local computer just in case.

At this point, you're clear to reboot back into the system.

## Using the system
In order to enter your LUKS password to decrypt the disks, you'll need to connect with Lish first. After it's successfully unlocked, the system will finish booting and you can access the system with SSH

## What if I break something and need to use rescue mode?
Connect to the Linode with Lish and then reboot it into rescue mode. When Finnix first starts, it'll try to mount the disk (and therefore prompt for your LUKS password).

If you miss this prompt, you can still mount it manually like so:

```shell
# *Note*: Entering your password directly on the Lish console will log it in
# the Linode's console log on the host. If you're security conscious, this is
# bad. Do this to enter password without visible console output.
read -rsp '> ' LUKSPASSWD
echo -n "$LUKSPASSWD" | cryptsetup luksOpen /dev/sdc crypt-sdc --key-file=-
mkdir -p /mnt/debian-root
mount -o defaults,noatime,compress=lzo,subvol=root /dev/mapper/crypt-sdc /mnt/debian-root
```

## License
This project is (jokingly) licensed under the [WTFPL](http://www.wtfpl.net/). Go nuts.

Full license can be found in 'LICENSE.md' file.
