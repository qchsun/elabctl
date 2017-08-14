#!/usr/bin/env bash
# https://www.elabftw.net

###############################################################
# CONFIGURATION
# where do you want your backups to end up?
declare BACKUP_DIR='/var/backups/elabftw'
# where do we store the config file?
declare CONF_FILE='/etc/elabftw.yml'
# where do we store the MySQL database and the uploaded files?
declare DATA_DIR='/var/elabftw'
# where do we store the logs?
declare LOG_FILE='/var/log/elabftw.log'
# END CONFIGURATION
###############################################################

declare -r MAN_FILE='/usr/share/man/man1/elabctl.1.gz'
declare -r ELABCTL_VERSION='0.5.0'
declare -r USER_CONF_FILE='/etc/elabctl.conf'

# Now we load the configuration file for custom directories set by user
if [ -f ${USER_CONF_FILE} ]; then
    source ${USER_CONF_FILE}
fi

# display ascii logo
function ascii()
{
    clear
    echo ""
    echo "       _         _       __  _             "
    echo "  ___ | |  ____ | |__   / _|| |_ __      __"
    echo " / _ \| | / _ ||| |_ \ | |_ | __|\ \ /\ / /"
    echo "|  __/| || (_| || |_) ||  _|| |_  \ V  V / "
    echo " \___||_| \__,_||_.__/ |_|   \__|  \_/\_/  "
    echo ""
    echo "If something goes wrong, have a look at ${LOG_FILE}!"
}

# create a mysqldump and a zip archive of the uploaded files
function backup()
{
    echo "Using backup directory "$BACKUP_DIR""

    if ! ls -A "${BACKUP_DIR}" > /dev/null 2>&1; then
        mkdir -p "${BACKUP_DIR}"
    fi

    set -e

    # get clean date
    local -r date=$(date --iso-8601) # 2016-02-10
    local -r zipfile="${BACKUP_DIR}/uploaded_files-${date}.zip"
    local -r dumpfile="${BACKUP_DIR}/mysql_dump-${date}.sql"

    # dump sql
    docker exec mysql bash -c 'mysqldump -u$MYSQL_USER -p$MYSQL_PASSWORD -r dump.sql $MYSQL_DATABASE' > /dev/null 2>&1
    # copy it from the container to the host
    docker cp mysql:dump.sql "$dumpfile"
    # compress it to the max
    gzip -f --best "$dumpfile"
    # make a zip of the uploads folder
    zip -rq "$zipfile" ${DATA_DIR}/web -x ${DATA_DIR}/web/tmp\*
    # add the config file
    zip -rq "$zipfile" $CONF_FILE

    echo "Done. Copy ${BACKUP_DIR} over to another computer."
}

function getUserconf()
{
    # do not overwrite a custom conf file
    if [ ! -f $USER_CONF_FILE ]; then
        wget -qO- https://github.com/elabftw/elabctl/raw/master/elabctl.conf > $USER_CONF_FILE
    fi
}

function getDeps()
{
    if [ "$ID" == "ubuntu" ] || [ "$ID" == "debian" ]; then
        echo "Synchronizing packages index. Please wait…"
        apt-get update >> $LOG_FILE 2>&1
    fi

    if ! hash dialog 2>/dev/null; then
        echo "Installing prerequisite package: dialog. Please wait…"
        install-pkg dialog
    fi

    if ! hash zip 2>/dev/null; then
        echo "Installing prerequisite package: zip. Please wait…"
        install-pkg zip
    fi

    if ! hash wget 2>/dev/null; then
        echo "Installing prerequisite package: wget. Please wait…"
        install-pkg wget
    fi

    if ! hash git 2>/dev/null; then
        echo "Installing prerequisite package: git. Please wait…"
        install-pkg git
    fi

}

function getDistrib()
{
    # let's first try to read /etc/os-release
    if test -e /etc/os-release
    then

        # source the file
        . /etc/os-release

        # pacman = package manager

        # DEBIAN / UBUNTU
        if [ "$ID" == "ubuntu" ] || [ "$ID" == "debian" ]; then
            PACMAN="apt-get -y install"

        # FEDORA
        elif [ "$ID" == "fedora" ]; then
            PACMAN="dnf -y install"

        # CENTOS
        elif [ "$ID" == "centos" ]; then
            PACMAN="yum -y install"
            # we need this to install python-pip
            install-pkg epel-release

        # RED HAT
        elif [ "$ID" == "rhel" ]; then
            PACMAN="yum -y install"

        # ARCH IS THE BEST
        elif [ "$ID" == "arch" ]; then
            PACMAN="pacman -Sy --noconfirm"

        # OPENSUSE
        elif [ "$ID" == "opensuse" ]; then
            PACMAN="zypper -n install"
        else
            echo "What distribution are you running? Please open a github issue!"
            exit 1
        fi
    # for CentOS 6.8, see #368
    elif grep -qi centos /etc/*-release
    then
        echo "It looks like you are using CentOS 6.8 which is using a very old kernel not compatible/stable with Docker. It is not recommended to use eLabFTW in Docker with this setup. Please have a look at the installation instructions without Docker."
        exit 1

    else
        echo "Could not load /etc/os-release to guess distribution. Please open a github issue!"
        exit 1
    fi
}

# install manpage
function getMan()
{
    wget -qO- https://github.com/elabftw/elabctl/raw/master/elabctl.1.gz > $MAN_FILE
}

function help()
{
    version
    echo "
    Usage: elabctl [OPTION] [COMMAND]
           elabctl [ --help | --version ]
           elabctl install
           elabctl backup

    Commands:

        backup          Backup your installation
        help            Show this text
        install         Configure and install required components
        logs            Show logs of the containers
        php-logs        Show last 15 lines of nginx error log
        refresh         Recreate the containers if they need to be
        restart         Restart the containers
        self-update     Update the elabctl script
        status          Show status of running containers
        start           Start the containers
        stop            Stop the containers
        uninstall       Uninstall eLabFTW and purge data
        update          Get the latest version of the containers
        version         Display elabctl version

    See 'man elabctl' for more informations."
}

# install pip and docker-compose, get elabftw.yml and configure it with sed
function install()
{
    # init vars
    # mysql passwords
    declare rootpass=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 12 | xargs)
    declare pass=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 12 | xargs)

    # if you don't want any dialog
    declare unattended=${ELAB_UNATTENDED:-0}
    declare servername=${ELAB_SERVERNAME:-localhost}
    declare hasdomain=${ELAB_HASDOMAIN:-0}
    declare email=${ELAB_EMAIL:-elabtest@yopmail.com}

    # exit on error
    set -e

    title="Install eLabFTW"
    backtitle="eLabFTW installation"

    ascii
    getDistrib
    getDeps

    # show welcome screen and ask if defaults are fine
    if [ $unattended -eq 0 ]; then
        # because answering No to dialog equals exit != 0
        set +e

        # welcome screen
        dialog --backtitle "$backtitle" --title "$title" --msgbox "\nWelcome to the install of eLabFTW :)\n
        This script will automatically install eLabFTW in a Docker container." 0 0

        dialog --backtitle "$backtitle" --title "$title" --yes-label "Looks good to me" --no-label "Download example conf and quit" --yesno "\nHere is what will happen:\n
        The main configuration file will be created at: ${CONF_FILE}\n
        The configuration file for elabctl will be created at: ${USER_CONF_FILE}\n
        A directory holding elabftw data (mysql + uploaded files) will be created at: ${DATA_DIR}\n
        A log file of the installation process will be created at: ${LOG_FILE}\n
        A man page will be added to your system\n
        The backups will be created at: ${BACKUP_DIR}\n\n
        If you wish to change the defaults paths, quit now and edit the file ${USER_CONF_FILE}" 0 0
        if [ $? -eq 1 ]; then
            echo "Downloading an example configuration file to ${USER_CONF_FILE}"
            getUserconf
            echo "Done. You can now edit this file and restart the installation afterwards."
            exit 0
        fi
    fi

    # create the data dir
    mkdir -p $DATA_DIR

    # do nothing if there are files in there
    if [ "$(ls -A $DATA_DIR)" ]; then
        echo "It looks like eLabFTW is already installed. Delete the ${DATA_DIR} folder to reinstall."
        exit 1
    fi

    getMan
    getUserconf

    if [ $unattended -eq 0 ]; then
        set +e
        # start asking questions
        ########################

        # server or local?
        dialog --backtitle "$backtitle" --title "$title" --yes-label "Server" --no-label "My computer" --yesno "\nAre you installing it on a Server or a personal computer?" 0 0
        if [ $? -eq 0 ]; then
            # server
            dialog --backtitle "$backtitle" --title "$title" --yes-label "Has a public IP/domain name" --no-label "Is behind a firewall" --yesno "\nCan this server be reached from internet or is it behind a firewall?" 0 0
            if [ $? -eq 0 ]; then
                # public ip

                # ask for domain name
                dialog --backtitle "$backtitle" --title "$title" --yesno "\nIs a domain name pointing to this server?\n\nAnswer yes if this server can be reached from outside using a domain name. In this case a proper SSL certificate will be requested from Let's Encrypt.\n\nAnswer no if you can only reach this server using an IP address or if the domain name is internal. In this case a self-signed certificate will be used." 0 0
                # domain name
                if [ $? -eq 0 ]; then
                hasdomain=1
                servername=$(dialog --backtitle "$backtitle" --title "$title" --inputbox "\nCool, we will use Let's Encrypt :)\n
    What is the domain name of this server?\n
    Example : elabftw.ktu.edu\n
    Enter your domain name:\n" 0 0 --output-fd 1)
                email=$(dialog --backtitle "$backtitle" --title "$title" --inputbox "\nLast question, what is your email?\n
    It is sent to Let's Encrypt only.\n
    Enter your email address:\n" 0 0 --output-fd 1)
                # no domain name
                else
                    # ask for ip
                    servername=$(dialog --backtitle "$backtitle" --title "$title" --inputbox "\nPlease enter your IP address below:" 0 0 --output-fd 1)
                fi

            # behind firewall; ask directly the user
            else
                servername=$(dialog --backtitle "$backtitle" --title "$title" --inputbox "\nPlease enter the local IP address below:" 0 0 --output-fd 1)
            fi

        else
            # computer
            servername="localhost"
        fi

    fi


    set -e

    echo 10 | dialog --backtitle "$backtitle" --title "$title" --gauge "Installing python-pip" 20 80
    install-pkg python-pip >> "$LOG_FILE" 2>&1

    echo 30 | dialog --backtitle "$backtitle" --title "$title" --gauge "Installing docker-compose" 20 80
    # make sure we have the latest pip version
    pip install --upgrade pip >> "$LOG_FILE" 2>&1
    pip install --upgrade docker-compose >> "$LOG_FILE" 2>&1

    echo 40 | dialog --backtitle "$backtitle" --title "$title" --gauge "Creating folder structure" 20 80
    mkdir -pv ${DATA_DIR}/{web,mysql} >> "$LOG_FILE" 2>&1
    chmod -R 700 ${DATA_DIR} >> "$LOG_FILE" 2>&1
    chown -v 999:999 ${DATA_DIR}/mysql >> "$LOG_FILE" 2>&1
    chown -v 100:101 ${DATA_DIR}/web >> "$LOG_FILE" 2>&1
    sleep 1

    echo 50 | dialog --backtitle "$backtitle" --title "$title" --gauge "Grabbing the docker-compose configuration file" 20 80
    # make a copy of an existing conf file
    if [ -e $CONF_FILE ]; then
        echo 55 | dialog --backtitle "$backtitle" --title "$title" --gauge "Making a copy of the existing configuration file." 20 80
        \cp $CONF_FILE ${CONF_FILE}.old
    fi

    wget -q https://raw.githubusercontent.com/elabftw/elabimg/master/src/docker-compose.yml-EXAMPLE -O "$CONF_FILE"
    # setup restrictive permissions
    chmod 600 "$CONF_FILE"
    sleep 1

    # elab config
    echo 50 | dialog --backtitle "$backtitle" --title "$title" --gauge "Adjusting configuration" 20 80
    secret_key=$(curl --silent https://demo.elabftw.net/install/generateSecretKey.php)
    sed -i -e "s/SECRET_KEY=/SECRET_KEY=$secret_key/" $CONF_FILE
    sed -i -e "s/SERVER_NAME=localhost/SERVER_NAME=$servername/" $CONF_FILE
    sed -i -e "s:/var/elabftw:${DATA_DIR}:" $CONF_FILE

    # enable letsencrypt
    if [ $hasdomain -eq 1 ]
    then
        sed -i -e "s:ENABLE_LETSENCRYPT=false:ENABLE_LETSENCRYPT=true:" $CONF_FILE
        sed -i -e "s:#- /etc/letsencrypt:- /etc/letsencrypt:" $CONF_FILE
    fi

    # mysql config
    sed -i -e "s/MYSQL_ROOT_PASSWORD=secr3t/MYSQL_ROOT_PASSWORD=$rootpass/" $CONF_FILE
    sed -i -e "s/MYSQL_PASSWORD=secr3t/MYSQL_PASSWORD=$pass/" $CONF_FILE
    sed -i -e "s/DB_PASSWORD=secr3t/DB_PASSWORD=$pass/" $CONF_FILE

    sleep 1

    if  [ $hasdomain -eq 1 ]
    then
        echo 60 | dialog --backtitle "$backtitle" --title "$title" --gauge "Installing letsencrypt in ${DATA_DIR}/letsencrypt" 20 80
        git clone --depth 1 --branch master https://github.com/letsencrypt/letsencrypt ${DATA_DIR}/letsencrypt >> $LOG_FILE 2>&1
        echo 65 | dialog --backtitle "$backtitle" --title "$title" --gauge "Allowing traffic on port 443" 20 80
        ufw allow 443/tcp || true
        echo 70 | dialog --backtitle "$backtitle" --title "$title" --gauge "Getting the SSL certificate" 20 80
        cd ${DATA_DIR}/letsencrypt && ./letsencrypt-auto certonly --standalone --email "$email" --agree-tos --non-interactive -d "$servername"
    fi

    # final screen
    if [ $unattended -eq 0 ]; then
        dialog --colors --backtitle "$backtitle" --title "Installation finished" --msgbox "\nCongratulations, eLabFTW was successfully installed! :)\n\n
        \Z1====>\Zn Start the containers with: \Zb\Z4elabctl start\Zn\n\n
        It will take a minute or two to run at first.\n\n
        \Z1====>\Zn Go to https://$servername once started!\n\n
        In the mean time, check out what to do after an install:\n
        \Z1====>\Zn https://elabftw.readthedocs.io/en/latest/postinstall.html\n\n
        The log file of the install is here: $LOG_FILE\n
        The configuration file for docker-compose is here: $CONF_FILE\n
        Your data folder is: ${DATA_DIR}. It contains the MySQL database and uploaded files.\n
        You can use 'docker logs -f elabftw' to follow the starting up of the container.\n
        See 'man elabctl' to backup or update." 20 80
    fi
}

function install-pkg()
{
    $PACMAN "$1" >> $LOG_FILE 2>&1
}

function logs()
{
    docker logs mysql
    docker logs elabftw
}

function php-logs()
{
    docker exec elabftw tail -n 15 /var/log/nginx/error.log
}

function refresh()
{
    start
}


function restart()
{
    stop
    start
}

function self-update()
{
    getMan
    wget -qO- https://raw.githubusercontent.com/elabftw/elabctl/master/elabctl.sh > /tmp/elabctl
    chmod +x /tmp/elabctl
    mv /tmp/elabctl /usr/bin/elabctl
}

function start()
{
    echo "Using configuration file "$CONF_FILE""
    docker-compose -f "$CONF_FILE" up -d
}

function status()
{
    docker ps
}

function stop()
{
    echo "Using configuration file "$CONF_FILE""
    docker-compose -f "$CONF_FILE" down
}

function uninstall()
{
    stop

    local -r backtitle="eLabFTW uninstall"
    local title="Uninstall"

    set +e

    dialog --backtitle "$backtitle" --title "$title" --yesno "\nWarning! You are about to delete everything related to eLabFTW on this computer!\n\nThere is no 'go back' button. Are you sure you want to do this?\n" 0 0
    if [ $? != 0 ]; then
        exit 1
    fi

    dialog --backtitle "$backtitle" --title "$title" --yesno "\nDo you want to delete the backups, too?" 0 0
    if [ $? -eq 0 ]; then
        rmbackup='y'
    else
        rmbackup='n'
    fi

    dialog --backtitle "$backtitle" --title "$title" --ok-label "Skip timer" --cancel-label "Cancel uninstall" --pause "\nRemoving everything in 10 seconds. Stop now you fool!\n" 20 40 10
    if [ $? != 0 ]; then
        exit 1
    fi

    clear

    # remove man page
    if [ -f "$MAN_FILE" ]; then
        rm -f "$MAN_FILE"
        echo "[x] Deleted $MAN_FILE"
    fi

    # remove config file and eventual backup
    if [ -f "${CONF_FILE}.old" ]; then
        rm -f "${CONF_FILE}.old"
        echo "[x] Deleted ${CONF_FILE}.old"
    fi
    if [ -f "$CONF_FILE" ]; then
        rm -f "$CONF_FILE"
        echo "[x] Deleted $CONF_FILE"
    fi
    # remove logfile
    if [ -f "$LOG_FILE" ]; then
        rm -f "$LOG_FILE"
        echo "[x] Deleted $LOG_FILE"
    fi
    # remove data directory
    if [ -d "$DATA_DIR" ]; then
        rm -rf "$DATA_DIR"
        echo "[x] Deleted $DATA_DIR"
    fi
    # remove backup dir
    if [ $rmbackup == 'y' ] && [ -d "$BACKUP_DIR" ]; then
        rm -rf "$BACKUP_DIR"
        echo "[x] Deleted $BACKUP_DIR"
    fi

    # remove docker images
    docker rmi elabftw/elabimg || true
    docker rmi mysql:5.7 || true

    echo ""
    echo "[✓] Everything has been obliterated. Have a nice day :)"
}

function update()
{
    echo "Using configuration file "$CONF_FILE""
    docker-compose -f "$CONF_FILE" pull
    restart
}

function upgrade()
{
    update
}

function usage()
{
    help
}

function version()
{
    echo "elabctl © 2017 Nicolas CARPi"
    echo "Version: $ELABCTL_VERSION"
}

# SCRIPT BEGIN

# root only
if [ $EUID != 0 ]; then
    echo "You don't have sufficient permissions. Try with:"
    echo "sudo elabctl $1"
    exit 1
fi

# only one argument allowed
if [ $# != 1 ]; then
    help
    exit 1
fi

# deal with --help and --version
case "$1" in
    -h|--help)
    help
    exit 0
    ;;
    -v|--version)
    version
    exit 0
    ;;
esac

# available commands
declare -A commands
for valid in backup help install logs php-logs self-update start status stop refresh restart uninstall update upgrade usage version
do
    commands[$valid]=1
done

if [[ ${commands[$1]} ]]; then
    # exit if variable isn't set
    set -u
    $1
else
    help
    exit 1
fi
