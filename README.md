# Ubuntu Perforce server setup script

This bash script will setup Perforce a good 90% of the way. Running all the commands you need to run it. Making it nice and easy to get setup and working.

## Why?

I had a few clients who wanted it setup and it was the same commands over and over again, so a quick bash script and now its easier than ever.

## Limitations
- Ubuntu based only - I tried to get it working on Debian what I normally use but either packages weren't available or they were out of date. Without a lot of messing around updating sources its just easier to use Ubuntu for now.

- Randomly sometimes the script will just stop running. No idea why. You can try to view the last thing it ran then re-run from there. If you can let me know WHICH bit it stopped on, I can try to fix.

## 🛠️ Installation Steps - development

Video:
https://youtu.be/P8DKbF6aQfk

1) Clone the repo / download the `perforce_server_setup.sh`

```bash
git clone https://github.com/d3kryption/ubuntu_perforce_server_setup
```

2) Move the bash file onto your server and run it as sudo.

```bash
sudo ./perforce_server_setup.sh
```

3) Some steps will pause execution and wait for you to enter some details to continue.

NOTE: The newest version of the script automates the Typemap part!

## Fixing a broken server 

Unfortunately things have to break. Its not fair, but thats why we have to fix it and continue.

Below is the most common issues when a server randomly breaks. If you are just first time installing it and its broken, I would not try these unless you are sure.

### How to find an error message

Annoyingly Perforce hides the error messages so you need to do a bit of hunting to find it. The most common commands to find it are below:

- Try just telling P4 to restart

`p4 admin restart` - if this errors with anything connection confused, try another command below

`journalctl -xeu helix-p4dctl.service` - This sometimes can highlight the error but if nothing stands out try another command below

`sudo -u perforce env P4SSLDIR=/mnt/<YOUR STORAGE>/root/ssl /opt/perforce/sbin/p4d -p ssl:1666 -r /mnt/YOUR STORAGE>/root` - This command (make sure you adjust it) should give you the final issue if the others don't.

### Upgrade / Reboot issue / Database it out of date error

In version **2024.1**, a fatal bug causes P4 to stop working when you UPDATE / UPGRADE. It can be resolved with the below steps.

1) Modify the file `nano /etc/perforce/p4dctl.conf.d/master.conf` (yours might not be master if you renamed it)

2) You need to add the lines above **P4ROOT**:
`P4PORT = SSL:YOUR IP ADDRESS:1666`
`P4LOG = /var/log/perforce/p4err`
`P4SSLDIR = /mnt/YOUR STORAGE LOCATION/root/ssl`

For example:

`P4PORT = SSL:10.10.10.10:1666`
`P4LOG = /var/log/perforce/p4err`
`P4SSLDIR = /mnt/mystorage/root/ssl`

3) Press CTRL+X to exit, Y to save, and then enter

4) Now upgrade the Perforce DB `sudo -u perforce /opt/perforce/sbin/p4d -r YOUR PERFORCE LOCATION/master/root -xu` e.g. `sudo -u perforce /opt/perforce/sbin/p4d -r /mnt/MyDrive/Perforce/master/root -xu`

5) Now reboot the Perforce service: `systemctl start helix-p4dctl.service` and then Perforce: `p4 admin restart`

### Certificate date range invalid

When perforce installs via SSL it sets up a certfiicate. These have expiry dates and when they expire, the server won't connect anymore.

1) Backup the existing SSL certs just in case:
`cp -r /mnt/YOUR STORAGE LOCATION/root/ssl /mnt/YOUR STORAGE LOCATION/root/ssl_backup`

2) Remove the old certs:
```
rm -f /mnt/YOUR STORAGE LOCATION/root/ssl/certificate.txt
rm -f /mnt/YOUR STORAGE LOCATION/root/ssl/privatekey.txt
```

3) Update the private cert:
`sudo -u perforce env P4SSLDIR=/mnt/YOUR STORAGE LOCATION/root/ssl /opt/perforce/sbin/p4d -r /mnt/YOUR STORAGE LOCATION/root -Gc`

4) Then update the public cert:
`sudo -u perforce env P4SSLDIR=/mnt/YOUR STORAGE LOCATION/root/ssl /opt/perforce/sbin/p4d -r /mnt/YOUR STORAGE LOCATION/root -Gf`

5) Now reboot the Perforce service: `systemctl start helix-p4dctl.service` and then Perforce: `p4 admin restart`
