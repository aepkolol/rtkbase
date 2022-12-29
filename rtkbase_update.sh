#!/bin/bash
### THIS SCRIPT SHOULD NOT BE RUN MANUALLY ###

#'shopt -s extglob' is needed for using (!pattern) exclusion pattern
#from inside a script
shopt -s extglob

#enable this line to send the script output to /var/log/syslog.
#exec 1> >(logger -s -t $(basename $0)) 2>&1

source_directory=$1
destination_directory=$2
data_dir=$3
old_version=$4
standard_user=$5

update() {
echo "remove existing rtkbase.old directory"
rm -rf /var/tmp/rtkbase.old
mkdir /var/tmp/rtkbase.old

echo "copy rtkbase to rtkbase.old except /data directory"
cp -r ${destination_directory}/!(${data_dir}) /var/tmp/rtkbase.old

#Don't do that or it will stop the update process
#systemctl stop rtkbase_web.service

echo "copy new release to destination"
cp -rfp ${source_directory}/. ${destination_directory}

}

insert_rtcm_msg() {
# inserting new message inside a rtcm message list
# and "return" the new strings with the ${new_rtcm} global variable
# it will try to insert it a the lowest possible position


    local text_line=${1}
    local msg_to_insert=${2}
    local highest_msg=${3}
    local delay=${4}
    
    new_rtcm=''
    if [[ ! $(echo ${text_line} | grep ${msg_to_insert}) ]]
    then
        for (( i=${msg_to_insert}; i<=${highest_msg}; i++ ))
            do
                if [[ $(echo ${text_line} | grep $i) ]]
                then
                    echo 'insert '${msg_to_insert}' before '$i
                    new_rtcm=$(echo ${text_line} | sed 's|'"${i}"'|'"${msg_to_insert}${delay}"',&|')
                    #echo ${new_rtcm}
                    break
                fi
            done
    else
        #msg already inside the string
        return 1
    fi
 }

upd_2.0.2() {
  if [[ $(grep -E "^receiver_format='ubx'" ${destination_directory}/settings.conf) ]]
  then
    # Add -TAJD=1 option to rtcm/ntrip output for ublox receivers
    grep -q "^ntrip_receiver_options" ${destination_directory}/settings.conf || \
      sed -i "/^rtcm_msg=.*/a ntrip_receiver_options='-TADJ=1'" ${destination_directory}/settings.conf
    grep -q "^rtcm_receiver_options" ${destination_directory}/settings.conf || \
      sed -i "/^rtcm_svr_msg=.*/a rtcm_receiver_options='-TADJ=1'" ${destination_directory}/settings.conf
  fi
  #upd_2.0.4
}

upd_2.1.0() {
  upd_2.1.1 "$@"
}

upd_2.1.1() {
  #stopping services to copy new rtklib app
  #systemctl stop rtkbase_web <- don't do that, it will kill this script process.
  systemctl stop str2str_tcp
  #Get Rtklib 2.4.3 b34 release
  wget -qO - https://github.com/tomojitakasu/RTKLIB/archive/v2.4.3-b34.tar.gz | tar -xvz
  #Install Rtklib app
  make --directory=RTKLIB-2.4.3-b34/app/consapp/str2str/gcc
  make --directory=RTKLIB-2.4.3-b34/app/consapp/str2str/gcc install
  make --directory=RTKLIB-2.4.3-b34/app/consapp/rtkrcv/gcc
  make --directory=RTKLIB-2.4.3-b34/app/consapp/rtkrcv/gcc install
  make --directory=RTKLIB-2.4.3-b34/app/consapp/convbin/gcc
  make --directory=RTKLIB-2.4.3-b34/app/consapp/convbin/gcc install
  #deleting RTKLIB
  rm -rf RTKLIB-2.4.3-b34/
  
  #restarting str2str_tcp service
  systemctl start str2str_tcp
  
  #update python module
  python3 -m pip install -r ${destination_directory}'/web_app/requirements.txt'
  
  #copying new service
  file_path=${destination_directory}'/unit/str2str_rtcm_serial.service'
  file_name=$(basename ${file_path})
  echo copying ${file_name}
  sed -e 's|{script_path}|'"$(readlink -f "$2")"'|' -e 's|{user}|'"${standard_user}"'|' ${file_path} > /etc/systemd/system/${file_name}
  systemctl daemon-reload

  #inserting new rtcm message 1008 and 1033 inside rtcm_msg and rtcm_svr_msg
  insert_rtcm_msg $(grep "^rtcm_msg=" ${destination_directory}/settings.conf) 1008 1042 '(10)' && \
      sed -i '/^rtcm_msg=/c\'"${new_rtcm}" ${destination_directory}/settings.conf
  insert_rtcm_msg $(grep "^rtcm_msg=" ${destination_directory}/settings.conf) 1033 1230 '(10)' && \
      sed -i '/^rtcm_msg=/c\'"${new_rtcm}" ${destination_directory}/settings.conf
  insert_rtcm_msg $(grep "^rtcm_svr_msg=" ${destination_directory}/settings.conf) 1008 1042 '(10)' && \
      sed -i '/^rtcm_svr_msg=/c\'"${new_rtcm}" ${destination_directory}/settings.conf
  insert_rtcm_msg $(grep "^rtcm_svr_msg=" ${destination_directory}/settings.conf) 1033 1230 '(10)' && \
      sed -i '/^rtcm_svr_msg=/c\'"${new_rtcm}" ${destination_directory}/settings.conf
  
  #restarting runnning rtcm services to send the new messages.
  # my bad ! these services are already stopped. the command bellow won't restart them
  #systemctl is-active --quiet str2str_ntrip && systemctl restart str2str_ntrip
  #systemctl is-active --quiet str2str_rtcm_svr && systemctl restart str2str_rtcm_svr
}

upd_2.2.0() {
  #update python module
  python3 -m pip install -r ${destination_directory}'/web_app/requirements.txt' --extra-index-url https://www.piwheels.org/simple
  
  #copying new service
  file_path=${destination_directory}'/unit/str2str_local_ntrip_caster.service'
  file_name=$(basename ${file_path})
  echo copying ${file_name}
  sed -e 's|{script_path}|'"$(readlink -f "$2")"'|' -e 's|{user}|'"${standard_user}"'|' ${file_path} > /etc/systemd/system/${file_name}

  #fix previous wrong path to run_cast.sh inside str2str_rtcm_serial.service during 2.1.1 to 2.2.0 update (/var/tmp/rtkbase/run_cast.sh)
  sed -i 's|'/var/tmp/rtkbase'|'"$(readlink -f "$2")"'|' /etc/systemd/system/str2str_rtcm_serial.service

  systemctl daemon-reload
}

upd_2.3.0() {
  upd_2.3.2 "$@"
}

upd_2.3.1() {
  upd_2.3.2 "$@"
}

upd_2.3.2() {
#Add restart condition in gpsd.service
  if ! grep -q '^Restart=' /etc/systemd/system/gpsd.service ; then
    sed -i '/^ExecStart=.*/a Restart=always' /etc/systemd/system/gpsd.service
    sed -i '/^Restart=always.*/a RestartSec=30' /etc/systemd/system/gpsd.service
  fi
  systemctl daemon-reload
  upd_2.3.3 "$@"
}

upd_2.3.3() {
 #update gpsd unit file
 cp /lib/systemd/system/gpsd.service /etc/systemd/system/gpsd.service
 sed -i 's/^After=.*/After=str2str_tcp.service/' /etc/systemd/system/gpsd.service
 sed -i '/^# Needed with chrony/d' /etc/systemd/system/gpsd.service
 #Add restart condition
 grep -qi '^Restart=' /etc/systemd/system/gpsd.service || sed -i '/^ExecStart=.*/a Restart=always' /etc/systemd/system/gpsd.service
 grep -qi '^RestartSec=' /etc/systemd/system/gpsd.service || sed -i '/^Restart=always.*/a RestartSec=30' /etc/systemd/system/gpsd.service
 #Add ExecStartPre condition to not start gpsd if str2str_tcp is not running. See https://github.com/systemd/systemd/issues/1312
 grep -qi '^ExecStartPre=' /etc/systemd/system/gpsd.service || sed -i '/^ExecStart=.*/i ExecStartPre=systemctl is-active str2str_tcp.service' /etc/systemd/system/gpsd.service
 systemctl daemon-reload
 systemctl restart gpsd  
 upd_2.3.4 "$@"
}

upgrade_rtklib() {
  bin_path=$(dirname $(command -v str2str))
  arch_package=$(dpkg --print-architecture)
  rm "${bin_path}"'/str2str' "${bin_path}"'/rtkrcv' "${bin_path}"'/convbin'
  if [[ -f "${destination_directory}"'/tools/bin/rtklib_b34g/'"${arch_package}"'/str2str' ]]
  then
    echo 'Copying new rtklib binary for ' "${arch_package}"
    cp "${destination_directory}"'/tools/bin/rtklib_b34g/'"${arch_package}"/str2str "${bin_path}"
    cp "${destination_directory}"'/tools/bin/rtklib_b34g/'"${arch_package}"/rtkrcv "${bin_path}"
    cp "${destination_directory}"'/tools/bin/rtklib_b34g/'"${arch_package}"/convbin "${bin_path}"
  else
    echo 'No binary available for ' "${arch_package}" '. We will build it from source'
    "${destination_directory}"'/tools/install.sh' --user "${standard_user}" --rtklib
  fi
}

upd_2.3.4() {
  str2str_active=$(systemctl is-active str2str_tcp)
  systemctl stop str2str_tcp
  #Add new requirements for v2.4
  ${destination_directory}'/tools/install.sh' --user "${standard_user}" --dependencies
  # Copy new services
  rm /etc/systemd/system/str2str_ntrip.service
  file_path=${destination_directory}'/unit/str2str_ntrip_A.service'
  file_name=$(basename ${file_path})
  echo copying ${file_name}
  sed -e 's|{script_path}|'"$(readlink -f "$2")"'|' -e 's|{user}|'"${standard_user}"'|' ${file_path} > /etc/systemd/system/${file_name}
  file_path=${destination_directory}'/unit/str2str_ntrip_B.service'
  file_name=$(basename ${file_path})
  echo copying ${file_name}
  sed -e 's|{script_path}|'"$(readlink -f "$2")"'|' -e 's|{user}|'"${standard_user}"'|' ${file_path} > /etc/systemd/system/${file_name}
  systemctl daemon-reload
#update rtklib binary to the one from rtklibexplorer fork.
  upgrade_rtklib
#update python module
  python3 -m pip install -r ${destination_directory}'/web_app/requirements.txt' --extra-index-url https://www.piwheels.org/simple
#restart str2str if it was active before upgrading rtklib
  if [ $str2str_active = "active" ]
  then
    systemctl start str2str_tcp
  fi
}

# standard update
update
# calling specific update function. If we are using v2.2.5, it will call the function upd_2.2.5
upd_${old_version} "$@"

# The new version numbers will be imported from settings.conf.default during the web server startup.
echo "Delete the line version= and checkpoint_version= in settings.conf"
sed -i '/^checkpoint_version=/d' ${destination_directory}/settings.conf
sed -i '/^version=/d' ${destination_directory}/settings.conf
echo 'Insert updated status in settings.conf'
sed -i '/^\[general\]/a updated=true' ${destination_directory}/settings.conf

#change rtkbase's content owner
chown -R ${standard_user}:${standard_user} ${destination_directory}

#if a reboot is needed
#systemctl reboot

echo "Restart web server"
systemctl restart rtkbase_web.service
