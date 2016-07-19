#!/bin/bash 
#===============================================================================
#
#          FILE:  openvas-configuration
# 
#         USAGE:  ./openvas-configuration
# 
#   DESCRIPTION:  export/import openvas configuration (only config, no results)
# 
#       OPTIONS:  -a <import|export> f <filename>
#  REQUIREMENTS:  ---
#        AUTHOR: Ryan Schulze (rs), ryan@ryanschulze.net
#       CREATED: 04/20/2015 04:54:28 PM CDT
#===============================================================================
#
# TODO:
# - put scanners in an array (new in version 8), pop them into the tasks
#
#===============================================================================

#===  FUNCTION  ================================================================
#          NAME:  initialize and cleanup
#   DESCRIPTION:  define and cleanup the environment for our needs
#===============================================================================

initialize() {
	# Treat unset variables as an error
	set -o nounset
	Action=
	DumpFile=
	TmpDir=$(mktemp --directory)
	ompconfig='/etc/openvas/omp.config'
	omp="omp --config-file=${ompconfig}"
	BaseDir="$(pwd)"
	declare -ga warnings=()
	declare -ga errors=()

	trap cleanup TERM EXIT # clean up if script exits
}

cleanup() {
	show_warnings
	show_errors
	[[ -d ${TmpDir} ]] && rm -rf "${TmpDir}"
	exit 0
}

#===  FUNCTION  ================================================================
#          NAME:  parse_args
#   DESCRIPTION:  parses the cli args
#    PARAMETERS:  $@
#===============================================================================
parse_args() { 
	while getopts ":ha:f:c:" Option
	do
		case $Option in
			a ) Action="${OPTARG}" ;;
			f ) DumpFile="${OPTARG/.tgz/}" ;;
			c ) ompconfig=${OPTARG} ; omp="omp --config-file=${ompconfig}" ;;
			* ) print_help ;;   # DEFAULT
		esac
	done
	shift $((OPTIND - 1))
}

#===  FUNCTION  ================================================================
#          NAME:  print_help
#   DESCRIPTION:  Prints help and exits
#===============================================================================
print_help() {
	echo "Usage: ${0##*/} -a import|export [ -f <filename> ] [ -c <configfile> ] [ -h ]"
	echo -e "-a import|export\timport or export the configuration"
	echo -e "-f <filename>\t\tFilename to store/load the configuration, use - for stdin/stdout (default)"
	echo -e "-c <configfile>\t\tSpecific omp config file to use, mandatory on imports"
	echo -e "-h \t\t\tprints this help"
	echo ""
	echo "e.g. ./${0##*/} -a export -f -"
	echo ""
	exit 0
}

#===  FUNCTION  ================================================================
#          NAME:  parse_xml
#   DESCRIPTION:  A small function to help up parse the xml file by splitting 
#                 stuff on < and >
#===============================================================================
parse_xml () {
	local IFS=\>
	local returncode=
	local key=
	local value=
	declare -g Tag
	declare -g Content

	read -d \< Tag Content
	returncode=$?

	unset Attribute
	declare -gA Attribute

	IFS=\   
	for attr in ${Tag#* }
	do
		if [[ $attr =~ = ]]; then
			key=${attr%%=*}
			value=$(tidy "${attr#*=}")
			Attribute[${key}]=${value}
		fi
	done

	Tag="$(trim "${Tag%% *}")"
	Content="$(trim "${Content}")"


	return ${returncode}
}
#-------------------------------------------------------------------------------
#  Just some small helper functions
#-------------------------------------------------------------------------------
tidy() {
	trim "${@}" | sed "s/^[\'\"]\(.*\)[\'\"]$/\1/"
}
trim() {
	local var="$*"
	var="${var#"${var%%[![:space:]]*}"}"   # remove leading whitespace characters
	var="${var%"${var##*[![:space:]]}"}"   # remove trailing whitespace characters
	echo -n "${var}"
}
in_array() {
  local element
  for element in "${@:2}"; do [[ "${element}" == "$1" ]] && return 0; done
  return 1
}

#===  FUNCTION  ================================================================
#          NAME:  output
#   DESCRIPTION:  A helper function for directing output to a file or stdout
#===============================================================================
output() {
	local suffix="${1:-.cfg}"
	local Output=

	if [[ ! -z ${DumpFile} && "${DumpFile}" != '-' ]] ; then
		Output="${TmpDir}/${DumpFile}${suffix}"
	else
		Output="/dev/stdout"
	fi
	cat - >> ${Output}
}

#===  FUNCTION  ================================================================
#          NAME:  warning/error
#   DESCRIPTION:  functions to store and display errors/warnings
#===============================================================================
warning() {
	warnings+=("${@}")
}
error() {
	errors+=("${@}")
}
show_warnings() {
	[[ ${#warnings[@]} -gt 0 ]] && echo && printf "WARNING: %s\n" "${warnings[@]}" >&2
}
show_errors() {
	[[ ${#errors[@]} -gt 0 ]] && echo && printf "ERROR: %s\n" "${errors[@]}" >&2
}

#===  FUNCTION  ================================================================
#          NAME:  pack
#   DESCRIPTION:  A helper function creating a tar of all the config
#===============================================================================
pack() {
	cd "${TmpDir}"
	tar -czf "${BaseDir}/${DumpFile}.tgz" -- *
}

#===  FUNCTION  ================================================================
#          NAME:  unpack
#   DESCRIPTION:  A helper function unpacking the dump package
#===============================================================================
unpack() {
	cd "${TmpDir}"
	if [[ -f "${BaseDir}/${DumpFile}.tgz" ]] ; then
		tar -xzf "${BaseDir}/${DumpFile}.tgz"
	elif [[ -f "${DumpFile}.tgz" ]] ; then
		tar -xzf "${BaseDir}/${DumpFile}.tgz"
	fi
}

#-------------------------------------------------------------------------------
#  functions to extract existing config from the server and convert it into 
#  insertable output
#-------------------------------------------------------------------------------

empty_trashcan() {
	$omp -iX '<empty_trashcan/>' >/dev/null
}

get_credentials() {
	local ReferenceCounter=0
	local ReferencePrefix='credential'
	local ReferenceUUID=
	local level=
	local Name=
	local Login=
	declare -gA Credentials

	echo "Requesting credentials"
	while parse_xml ; do
		case ${Tag} in
			# beginning of data, reset fields
			lsc_credential  )
					ReferenceCounter=$((++ReferenceCounter))
					ReferenceUUID="${Attribute[id]}"
					Name=
					Login=
					level='global'
					;;
			# end of data, save it
			/lsc_credential )
					{
						printf "%s_%s@%s\n" \
						"${ReferencePrefix}" "${ReferenceCounter}" "${Name}"
					} | output
					# store forward and reverse references in the same array. ugly but makes lookups easier and they don't bother each other
					Credentials[${ReferenceCounter}]="${ReferenceUUID}"
					Credentials[${ReferenceUUID}]="${ReferenceCounter}"
					;;
			owner   ) level='owner' ;;
			/owner  ) level='global' ;;
			permissions  ) level='permissions' ;;
			/permissions ) level='global' ;;
			name    )  
					case "${level}" in
						global    ) Name="${Content}" ;;
					esac
					;;
		esac
	done < <($omp -iX '<get_lsc_credentials/>')
	if [[ ${ReferenceCounter} -gt 0 ]] ; 
	then
		warning "Credentials found, you will have to import them manually since there is no way to export the private key via OMP (or generate new credentials with the same name)."
	fi
}

get_filters() {
	local ReferenceCounter=0
	local ReferencePrefix='filter'
	local ReferenceUUID=
	local level=
	local Name=
	local Comment=
	local Term=
	local Type=
	declare -gA Filters

	echo "Requesting filters"
	while parse_xml ; do
		case ${Tag} in
			# beginning of data, reset fields
			filter  )
					ReferenceCounter=$((++ReferenceCounter))
					ReferenceUUID="${Attribute[id]}"
					Name=
					Comment=
					Term=
					Type=
					level='global'
					;;
			# end of data, save it
			/filter )
					{
						printf "%s_%s@%s\n" \
						"${ReferencePrefix}" "${ReferenceCounter}" "${Name}"
					} | output
					{
						printf "<create_filter>\n <name>%s</name>\n <comment>%s</comment>\n <term>%s</term>\n <type>%s</type>\n</create_filter>" \
						"${Name}" "${Comment}" "${Term}" "${Type}" 
						echo
					} | output _${ReferencePrefix}_${ReferenceCounter}.xml
					# store forward and reverse references in the same array. ugly but makes lookups easier and they don't bother each other
					Filters[${ReferenceCounter}]="${ReferenceUUID}"
					Filters[${ReferenceUUID}]="${ReferenceCounter}"
					;;
			owner   ) level='owner' ;;
			/owner  ) level='global' ;;
			permissions  ) level='permissions' ;;
			/permissions ) level='global' ;;
			name    )  
					case "${level}" in
						global    ) Name="${Content}" ;;
					esac
					;;
			comment )  
					case "${level}" in
						global    ) Comment="${Content}" ;;
					esac
					;;
			type    )  
					case "${level}" in
						global    ) Type="${Content}" ;;
					esac
					;;
			term    )  
					case "${level}" in
						global    ) Term="${Content}" ;;
					esac
					;;
		esac
	done < <($omp -iX '<get_filters/>')
}

get_report_formats() {
	local ReferenceCounter=0
	local ReferenceUUID=
	local ReferencePrefix='reportformat'
	local Name=
	local level=
	declare -gA ReportFormats

	echo "Requesting report formats"
	while parse_xml ; do
		case ${Tag} in
			report_format  )
					ReferenceCounter=$((++ReferenceCounter))
					ReferenceUUID="${Attribute[id]}"
					Name=
					level='global'
					;;
			/report_format  )
					{
						printf "%s_%s@%s\n" \
						"${ReferencePrefix}" "${ReferenceCounter}" "${Name}"
					} | output
					{
						echo "<create_report_format>"
						$omp -iX "<get_report_formats details='1' report_format_id='${ReferenceUUID}'/>" 
						echo "</create_report_format>"
					} | output _${ReferencePrefix}_${ReferenceCounter}.xml
					ReportFormats[${ReferenceCounter}]="${ReferenceUUID}"
					ReportFormats[${ReferenceUUID}]="${ReferenceCounter}"
					;;					
			owner   ) level='owner' ;;
			/owner  ) level='global' ;;
			permissions  ) level='permissions' ;;
			/permissions ) level='global' ;;
			name    )  
					case "${level}" in
						global    ) Name="${Content}" ;;
					esac
					;;
			esac
	done < <($omp -iX '<get_report_formats/>')
}

get_slaves() {
	local ReferenceCounter=0
	local ReferencePrefix='slave'
	local ReferenceUUID=
	local level=
	local Name=
	local Comment=
	local Host=
	local Port=
	local Login=
	local Password=
	declare -gA Slaves
	Password="$(grep ^password= "${ompconfig}" | cut -d= -f2)"

	echo "Requesting slaves"
	while parse_xml ; do
		case ${Tag} in
			# beginning of data, reset fields
			slave  )
					ReferenceCounter=$((++ReferenceCounter))
					ReferenceUUID="${Attribute[id]}"
					Name=
					Comment=
					Host=
					Port=
					Login=
					level='global'
					;;
			# end of data, save it
			/slave )
					{
						printf "%s_%s@%s\n" \
						"${ReferencePrefix}" "${ReferenceCounter}" "${Name}"
					} | output
					{
						printf "<create_slave>\n <name>%s</name>\n <comment>%s</comment>\n <host>%s</host>\n <port>%s</port>\n <login>%s</login>\n <password>%s</password>\n</create_slave>" \
						"${Name}" "${Comment}" "${Host}" "${Port}" "${Login}" "${Password}"
						echo
					} | output _${ReferencePrefix}_${ReferenceCounter}.xml
					# store forward and reverse references in the same array. ugly but makes lookups easier and they don't bother each other
					Slaves[${ReferenceCounter}]="${ReferenceUUID}"
					Slaves[${ReferenceUUID}]="${ReferenceCounter}"
					;;
			owner   ) level='owner' ;;
			/owner  ) level='global' ;;
			permissions  ) level='permissions' ;;
			/permissions ) level='global' ;;
			name    )
					case "${level}" in
						global    ) Name="${Content}" 
					esac
					;;
			comment )
					case "${level}" in
						global    ) Comment="${Content}"
					esac
					;;
			host    )
					case "${level}" in
						global    ) Host="${Content}"
					esac
					;;
			login    )
					case "${level}" in
						global    ) Login="${Content}"
					esac
					;;
			port    )
					case "${level}" in
						global    ) Port="${Content}"
					esac
					;;
		esac
	done < <($omp -iX '<get_slaves/>')
}

get_alerts() {
	local ReferenceCounter=0
	local ReferencePrefix='alert'
	local ReferenceUUID=
	local Name=
	local Comment=
	local Filter=
	local Condition=
	local ConditionData=
	local ConditionDataName=
	local Event=
	local EventData=
	local EventDataName=
	local Method=
	local MethodTmpdata=
	local ReportFormatUUID=
	local level=
	declare -A MethodData=
	declare -gA Alerts

	echo "Requesting alerts"
	while parse_xml ; do
		case ${Tag} in
			# beginning of data, reset fields
			alert  )
					ReferenceCounter=$((++ReferenceCounter))
					ReferenceUUID="${Attribute[id]}"
					Name=
					Comment=
					Filter=
					Condition=
					ConditionData=
					ConditionDataName=
					Event=
					EventData=
					EventDataName=
					Method=
					MethodTmpdata=
					unset MethodData
					declare -A MethodData=
					level='global'
					;;
			# end of data, save it
			/alert )
					{
						printf "%s_%s@%s\n" \
						"${ReferencePrefix}" "${ReferenceCounter}" "${Name}"
					} | output
					{
						printf "<create_alert>\n <name>%s</name>\n <comment>%s</comment>" "${Name}" "${Comment}"
						printf "\n <condition>%s<data>%s<name>%s</name></data></condition>" "${Condition}" "${ConditionData}" "${ConditionDataName}"
						printf "\n <event>%s<data>%s<name>%s</name></data></event>" "${Event}" "${EventData}" "${EventDataName}"
						if [[ ! -z ${Filter} ]] ; then
							printf "\n <filter id=\"%s\"/>" "filter_${Filters[$Filter]}"
						fi
						printf "\n <method>%s" "${Method}"
						for entry in "${!MethodData[@]}"
						do
							if [[ "${entry}" == 'notice_attach_format' ]] ; then
								ReportFormatUUID="${MethodData[$entry]}"
								MethodData[$entry]="reportformat_${ReportFormats[$ReportFormatUUID]}"
							fi
							printf "<data>%s<name>%s</name></data>" "${MethodData[$entry]}" "${entry}"
						done
						echo -e "</method>\n</create_alert>"
					} | output _${ReferencePrefix}_${ReferenceCounter}.xml
					# store forward and reverse references in the same array. ugly but makes lookups easier and they don't bother each other
					Alerts[${ReferenceCounter}]="${ReferenceUUID}"
					Alerts[${ReferenceUUID}]="${ReferenceCounter}"
					;;
			owner         ) level='owner' ;;
			permissions   ) level='permissions' ;;
			condition     ) level='condition' ; Condition="${Content}" ;;
			event         ) level='event' ; Event="${Content}" ;;
			method        ) level='method' ; Method="${Content}" ;;
			/owner        ) level='global' ;;
			/permissions  ) level='global' ;;
			/condition    ) level='global' ;;
			/event        ) level='global' ;;
			/method       ) level='global' ;;
			name    )
					case "${level}" in
						global    ) Name="${Content}" ;;
						condition ) ConditionDataName="${Content}" ;;
						event     ) EventDataName="${Content}" ;;
						method    ) MethodData[${Content}]="${MethodTmpdata}" ;;
					esac
					;;
			comment ) 
					case "${level}" in
						global    ) Comment="${Content}" 
					esac 
					;;
			data    )
					case "${level}" in
						condition ) ConditionData="${Content}" ;;
						event     ) EventData="${Content}" ;;
						method    ) MethodTmpdata="${Content}" ;;
					esac
					;;
			filter  )
					case "${level}" in
						global    ) Filter="${Attribute[id]}"
					esac
					;;
			/data   ) 
					case "${level}" in
						method    ) MethodTmpdata=
						;;
					esac
					;;
		esac
	done < <($omp -iX '<get_alerts/>')
}

get_schedules() {
	local ReferenceCounter=0
	local ReferencePrefix='schedule'
	local ReferenceUUID=
	local Name=
	local Comment=
	local FirstTimeDayOfMonth=
	local FirstTimeHour=
	local FirstTimeMinute=
	local FirstTimeMonth=
	local FirstTimeYear=
	local Duration=
	local DurationUnit=
	local Period=
	local PeriodUnit=
	local level=
	declare -gA Schedules

	echo "Requesting schedules"
	while parse_xml ; do
		case ${Tag} in
			# beginning of data, reset fields
			schedule )
					ReferenceCounter=$((++ReferenceCounter))
					ReferenceUUID="${Attribute[id]}"
					Name=
					Comment=
					FirstTimeDayOfMonth=
					FirstTimeHour=
					FirstTimeMinute=
					FirstTimeMonth=
					FirstTimeYear=
					Duration=
					DurationUnit=
					Period=
					PeriodUnit=
					level='global'
					;;
			# end of data, save it
			/schedule )
					{
						printf "%s_%s@%s\n" \
						"${ReferencePrefix}" "${ReferenceCounter}" "${Name}"
					} | output
					{
						printf "<create_schedule><name>%s</name><comment>%s</comment>" "${Name}" "${Comment}"
						printf "<first_time><day_of_month>%s</day_of_month><hour>%s</hour><minute>%s</minute><month>%s</month><year>%s</year></first_time>" \
						"${FirstTimeDayOfMonth}" "${FirstTimeHour}" "${FirstTimeMinute}" "${FirstTimeMonth}" "${FirstTimeYear}"
						printf "<duration>%s<unit>%s</unit></duration>" "${Duration}" "${DurationUnit}"
						printf "<period>%s<unit>%s</unit></period>" "${Period}" "${PeriodUnit}"
						echo "</create_schedule>"
					} | output _${ReferencePrefix}_${ReferenceCounter}.xml
					# store forward and reverse references in the same array. ugly but makes lookups easier and they don't bother each other
					Schedules[${ReferenceCounter}]="${ReferenceUUID}"
					Schedules[${ReferenceUUID}]="${ReferenceCounter}"
					;;
			owner   ) level='owner' ;;
			/owner  ) level='global' ;;
			permissions  ) level='permissions' ;;
			/permissions ) level='global' ;;
			simple_period  ) Period="${Content}" ; level='period' ;;
			/simple_period ) level='global' ;;
			simple_duration   ) Duration="${Content}" ; level='duration' ;;
			/simple_duration  ) level='global' ;;
			name    )
					case "${level}" in
						global    ) Name="${Content}" ;;
					esac
					;;
			comment ) 
					case "${level}" in
						global    ) Comment="${Content}" 
					esac 
					;;
			unit    )
					case "${level}" in
						duration  ) DurationUnit="${Content}" ;;
						period    ) PeriodUnit="${Content}" ;;
					esac
					;;
			first_time )
					FirstTimeDayOfMonth="$(date -d "${Content}" +%d)"
					FirstTimeHour="$(date -d "${Content}" +%H)"
					FirstTimeMinute="$(date -d "${Content}" +%M)"
					FirstTimeMonth="$(date -d "${Content}" +%m)"
					FirstTimeYear="$(date -d "${Content}" +%Y)"
					;;
		esac
	done < <($omp -iX '<get_schedules/>')
}

get_scan_config() {
	local ReferenceCounter=0
	local ReferenceUUID=
	local ReferencePrefix='scanconfig'
	local Name=
	local level=
	declare -gA ScanConfigs

	echo "Requesting scan configs"
	while parse_xml ; do
		case ${Tag} in
			config  )
					ReferenceCounter=$((++ReferenceCounter))
					ReferenceUUID="${Attribute[id]}"
					Name=
					level='global'
					;;
			/config )
					{
						printf "%s_%s@%s\n" "${ReferencePrefix}" "${ReferenceCounter}" "${Name}"
					} | output
					{
						echo "<create_config>"
						$omp -iX "<get_configs details='1' config_id='${ReferenceUUID}'/>"
						echo "</create_config>"
					} | output _scan_config_${ReferenceCounter}.xml
					ScanConfigs[${ReferenceCounter}]="${ReferenceUUID}"
					ScanConfigs[${ReferenceUUID}]="${ReferenceCounter}"					
					;;
			owner   ) level='owner' ;;
			/owner  ) level='global' ;;
			permissions  ) level='permissions' ;;
			/permissions ) level='global' ;;
			name    )
					case "${level}" in
						global    ) Name="${Content}" ;;
					esac
					;;								
		esac
	done < <($omp -iX '<get_configs/>')
}

get_targets() {
	local ReferenceCounter=0
	local ReferencePrefix='target'
	local ReferenceUUID=
	local Name=
	local Comment=
	local Hosts=
	local SMBCredential=
	local SSHCredential=
	local SSHCredentialPort=
	local ESXICredential=
	local AliveTest=
	local PortList=
	local level=
	declare -gA Targets

	echo "Requesting targets"
	while parse_xml ; do
		case ${Tag} in
			# beginning of data, reset fields
			target )
					ReferenceCounter=$((++ReferenceCounter))
					ReferenceUUID="${Attribute[id]}"
					Name=
					Comment=
					Hosts=
					Credential=
					CredentialPort=
					AliveTest=
					PortList=
					level='global'
					;;
			# end of data, save it
			/target )
					{
						printf "%s_%s@%s\n" "${ReferencePrefix}" "${ReferenceCounter}" "${Name}"
					} | output
					{
						printf "<create_target><name>%s</name><comment>%s</comment>" "${Name}" "${Comment}"
						printf "<hosts>%s</hosts><alive_tests>%s</alive_tests>" "${Hosts}" "${AliveTest}"
						if [[ ! -z ${SSHCredential} ]] ; then
							printf "<ssh_lsc_credential id=\"%s\"><port>%s</port></ssh_lsc_credential>" "credential_${Credentials[$SSHCredential]}" "${SSHCredentialPort}"
						fi
						if [[ ! -z ${SMBCredential} ]] ; then
							printf "<smb_lsc_credential id=\"%s\"></smb_lsc_credential>" "credential_${Credentials[$SMBCredential]}"
						fi
						if [[ ! -z ${PortList} ]] ; then
							printf "<port_list id=\"%s\"/>" "${PortList}"
						fi
						echo "</create_target>"
					} | output _${ReferencePrefix}_${ReferenceCounter}.xml
					# store forward and reverse references in the same array. ugly but makes lookups easier and they don't bother each other
					Targets[${ReferenceCounter}]="${ReferenceUUID}"
					Targets[${ReferenceUUID}]="${ReferenceCounter}"
					;;
			owner               ) level='owner' ;;
			permissions         ) level='permissions' ;;
			ssh_lsc_credential  ) SSHCredential="${Attribute[id]}" ; level='sshcredential' ;;
			smb_lsc_credential  ) SMBCredential="${Attribute[id]}" ; level='smbcredential' ;;
			esxi_lsc_credential ) ESXICredential="${Attribute[id]}" ; level='esxicredential' ;;
			port_list           ) PortList="${Attribute[id]}" ; level='portlist' ;;
			/owner              ) level='global' ;;
			/permissions        ) level='global' ;;
			/ssh_lsc_credential ) level='global' ;;
			/smb_lsc_credential ) level='global' ;;
			/esxi_lsc_credential ) level='global' ;;
			/port_list          ) level='global' ;;
			name    )
					case "${level}" in
						global    ) Name="${Content}" ;;
					esac
					;;
			comment ) 
					case "${level}" in
						global    ) Comment="${Content}" ;;
					esac 
					;;
			hosts   )
					case "${level}" in
						global    ) Hosts="${Content}" ;;
					esac
					;;
			alive_tests )
					case "${level}" in
						global    ) AliveTest="${Content}" ;;
					esac
					;;
			port    )
					case "${level}" in
						sshcredential ) SSHCredentialPort="${Content}" ;;
					esac
					;;
		esac
	done < <($omp -iX '<get_targets/>')
}

get_tasks() {
	local ReferenceCounter=0
	local ReferencePrefix='task'
	local ReferenceUUID=
	local Name=
	local Comment=
	local Alterable=
	local ScanConfig=
	local Target=
	local Slave=
	local Scanner=
	local Schedule=
	local PreferenceName=
	local level=
	local AlertList=
	declare -A Preferece=
	declare -gA Tasks

	echo "Requesting tasks"
	while parse_xml ; do
		case ${Tag} in
			# beginning of data, reset fields
			task )
					ReferenceCounter=$((++ReferenceCounter))
					ReferenceUUID="${Attribute[id]}"
					Name=
					Comment=
					ScanConfig=
					Target=
					Slave=
					Schedule=
					PreferenceName=
					AlertList=
					unset Preferece
					declare -A Preferece=										
					level='global'
					;;
			# end of data, save it
			/task )
					{
						printf "%s_%s@%s\n" "${ReferencePrefix}" "${ReferenceCounter}" "${Name}"
					} | output
					{
						printf "<create_task><name>%s</name><comment>%s</comment>" "${Name}" "${Comment}" 
						if [[ ! -z ${Alterable} ]] ; then
							printf "<alterable>%s</alterable>" "${Alterable}"
						fi
						printf "<config id=\"%s\"/>" "scanconfig_${ScanConfigs[$ScanConfig]}"
						printf "<target id=\"%s\"/>" "target_${Targets[$Target]}"
						if [[ ! -z ${Slave} ]] ; then
							printf "<slave id=\"%s\"/>" "slave_${Slaves[$Slave]}"
						fi
						if [[ ! -z ${Schedule} ]] ; then
							printf "<schedule id=\"%s\"/>" "schedule_${Schedules[$Schedule]}"
						fi
						if [[ ! -z ${Scanner} ]] ; then
							printf "<scanner id=\"%s\"/>" "${Scanner}"
						fi
						for entry in ${AlertList}
						do
							printf "<alert id=\"%s\"/>" "alert_${Alerts[$entry]}"
						done
						if [[ ${#Preferece[@]} -gt 0 ]] ; then
							echo -n '<preferences>'
							for entry in "${!Preferece[@]}"
							do
								if [[ "${entry}" == 'auto_delete_data' && "${Preferece[$entry]}" == '0' ]] ; then
									Preferece[$entry]=5
								fi
								printf "<preference><scanner_name>%s</scanner_name><value>%s</value></preference>" "${entry}" "${Preferece[$entry]}" 
							done
							echo -n '</preferences>'
						fi
						echo "</create_task>"
					} | output _${ReferencePrefix}_${ReferenceCounter}.xml
					# store forward and reverse references in the same array. ugly but makes lookups easier and they don't bother each other
					Tasks[${ReferenceCounter}]="${ReferenceUUID}"
					Tasks[${ReferenceUUID}]="${ReferenceCounter}"
					;;
			owner               ) level='owner' ;;
			permissions         ) level='permissions' ;;
			config              ) level='scanconfig' ; ScanConfig="${Attribute[id]}" ;;
			target              ) level='target' ; Target="${Attribute[id]}" ;;
			slave               ) level='slave' ; Slave="${Attribute[id]}" ;;
			schedule            ) level='schedule' ; Schedule="${Attribute[id]}" ;;
			scanner             ) level='scanner' ; Scanner="${Attribute[id]}" ;;
			current_report      ) level='currentreport' ;;
			first_report        ) level='firstreport' ;;
			last_report         ) level='lastreport' ;;
			second_last_report  ) level='2ndlastreport' ;;
			alert               ) level='alert' ; AlertList="${AlertList} ${Attribute[id]}" ;;
			preference          ) level='preference' ;;
			/owner              ) level='global' ;;
			/permissions        ) level='global' ;;
			/config             ) level='global' ;;
			/target             ) level='global' ;;
			/slave              ) level='global' ;;
			/scanner            ) level='global' ;;
			/schedule           ) level='global' ;;
			/current_report     ) level='global' ;;
			/first_report       ) level='global' ;;
			/last_report        ) level='global' ;;
			/second_last_report ) level='global' ;;
			/alert              ) level='global' ;;
			/preference         ) level='global' ; PreferenceName=;;
			name    )
					case "${level}" in
						global    ) Name="${Content}" ;;
					esac
					;;
			comment ) 
					case "${level}" in
						global    ) Comment="${Content}" ;;
					esac 
					;;
			alterable )
					case "${level}" in
						global  ) Alterable="${Content}" ;;
					esac
					;;
            scanner_name )
					case "${level}" in
						preference  ) PreferenceName="${Content}" ;;
					esac
					;;
            value )
					case "${level}" in
						preference  ) Preferece[$PreferenceName]="${Content}" ;;
					esac
					;;
		esac
	done < <($omp -iX '<get_tasks/>')
}

get_notes() {
	local ReferenceCounter=0
	local ReferencePrefix='note'
	local ReferenceUUID=
	local Text=
	local Nvt=
	local Name=
	local Active=
	local Hosts=
	local Port=
	local Task=
	local EndTime=
	local Severity=
	local level=
	declare -gA Notes

	echo "Requesting notes"
	while parse_xml ; do
		case ${Tag} in
			# beginning of data, reset fields
			note )
					ReferenceCounter=$((++ReferenceCounter))
					ReferenceUUID="${Attribute[id]}"
					Text=
					Nvt=
					Name=
					Active=
					Hosts=
					Port=
					Task=
					Severity=
					level='global'
					;;
			# end of data, save it
			/note )
					{
						printf "%s_%s@%s\n" "${ReferencePrefix}" "${ReferenceCounter}" "${Name}"
					} | output
					{
						printf "<create_note><text>%s</text>" "${Text}"
						printf "<nvt oid=\"%s\"/>" "${Nvt}"
						if [[ ! -z ${Hosts} ]] ; then
							printf "<hosts>%s</hosts>" "${Hosts}"
						fi
						if [[ ! -z ${Port} ]] ; then
							printf "<port>%s</port>" "${Port}"
						fi
						if [[ ! -z ${Task} ]] ; then
							printf "<task id=\"%s\"/>" "task_${Tasks[$Task]}"
						fi
						if [[ ! -z ${Severity} ]] ; then
							printf "<severity>%s</severity>" "${Severity}"
						fi
						if [[ -z ${EndTime} && ${Active} -eq 1 ]] ; then
							printf "<active>-1</active>"
						fi
						if [[ ! -z ${EndTime} && ${Active} -eq 1 ]] ; then
							Endtime="$(($(date -d "${EndTime}" +%s) -$(date +%s)))"
							printf "<active>%s</active>" "${Endtime}"
						fi
						if [[ ${Active} -eq 0 ]] ; then
							printf "<active>0</active>"
						fi
						echo "</create_note>"
					} | output _${ReferencePrefix}_${ReferenceCounter}.xml
					# store forward and reverse references in the same array. ugly but makes lookups easier and they don't bother each other
					Notes[${ReferenceCounter}]="${ReferenceUUID}"
					Notes[${ReferenceUUID}]="${ReferenceCounter}"
					;;
			owner               ) level='owner' ;;
			permissions         ) level='permissions' ;;
			nvt                 ) level='nvt' ; Nvt="${Attribute[oid]}" ;;
			task                ) level='task' ; Task="${Attribute[id]}" ;;
			text                ) level='text' ; Text="${Content//$'\n'/#n}" ;;
			result              ) level='result' ;;
			/owner              ) level='global' ;;
			/permissions        ) level='global' ;;
			/nvt                ) level='global' ;;
			/task               ) level='global' ;;
			/result             ) level='global' ;;
			/text               ) level='global' ;;
			active  )
					case "${level}" in
						global  ) Active="${Content}" ;;
					esac
					;;
			end_time  )
					case "${level}" in
						global  ) EndTime="${Content}" ;;
					esac
					;;
            hosts   )
					case "${level}" in
						global  ) Hosts="${Content}" ;;
					esac
					;;
            port    )
					case "${level}" in
						global  ) Port="${Content}" ;;
					esac
					;;
			severity )
					case "${level}" in
						global  ) Severity="${Content}" ;;
					esac
					;;
			name )
					case "${level}" in
						nvt  ) Severity="${Content}" ;;
					esac
					;;
		esac
	done < <($omp -iX '<get_notes details="1"/>')
}

get_overrides() {
	local ReferenceCounter=0
	local ReferencePrefix='override'
	local ReferenceUUID=
	local Text=
	local Nvt=
	local Name=
	local Active=
	local Hosts=
	local Port=
	local Task=
	local EndTime=
	local Severity=
	local NewSeverity=
	local level=
	declare -gA Overrides

	echo "Requesting overrides"
	while parse_xml ; do
		case ${Tag} in
			# beginning of data, reset fields
			override )
					ReferenceCounter=$((++ReferenceCounter))
					ReferenceUUID="${Attribute[id]}"
					Text=
					Nvt=
					Name=
					Active=
					Hosts=
					Port=
					Task=
					Severity=
					NewSeverity=
					level='global'
					;;
			# end of data, save it
			/override )
					{
						printf "%s_%s@%s\n" "${ReferencePrefix}" "${ReferenceCounter}" "${Name}"
					} | output
					{
						printf "<create_override><text>%s</text>" "${Text}"
						printf "<nvt oid=\"%s\"/>" "${Nvt}"
						if [[ ! -z ${Hosts} ]] ; then
							printf "<hosts>%s</hosts>" "${Hosts}"
						fi
						if [[ ! -z ${Port} ]] ; then
							printf "<port>%s</port>" "${Port}"
						fi
						if [[ ! -z ${Task} ]] ; then
							printf "<task id=\"%s\"/>" "task_${Tasks[$Task]}"
						fi
						if [[ ! -z ${Severity} ]] ; then
							printf "<severity>%s</severity>" "${Severity}"
						fi
						if [[ ! -z ${NewSeverity} ]] ; then
							printf "<new_severity>%s</new_severity>" "${NewSeverity}"
						fi
						if [[ -z ${EndTime} && ${Active} -eq 1 ]] ; then
							printf "<active>-1</active>"
						fi
						if [[ ! -z ${EndTime} && ${Active} -eq 1 ]] ; then
							Endtime="$(($(date -d "${EndTime}" +%s) -$(date +%s)))"
							printf "<active>%s</active>" "${Endtime}"
						fi
						if [[ ${Active} -eq 0 ]] ; then
							printf "<active>0</active>"
						fi
						echo "</create_override>"					
					} | output _${ReferencePrefix}_${ReferenceCounter}.xml
					# store forward and reverse references in the same array. ugly but makes lookups easier and they don't bother each other
					Overrides[${ReferenceCounter}]="${ReferenceUUID}"
					Overrides[${ReferenceUUID}]="${ReferenceCounter}"
					;;
			owner               ) level='owner' ;;
			permissions         ) level='permissions' ;;
			nvt                 ) level='nvt' ; Nvt="${Attribute[oid]}" ;;
			task                ) level='task' ; Task="${Attribute[id]}" ;;
			text                ) level='text' ; Text="${Content//$'\n'/#n}" ;;
			result              ) level='result' ;;
			/owner              ) level='global' ;;
			/permissions        ) level='global' ;;
			/nvt                ) level='global' ;;
			/task               ) level='global' ;;
			/result             ) level='global' ;;
			/text               ) level='global' ;;
			active  )
					case "${level}" in
						global  ) Active="${Content}" ;;
					esac
					;;
			end_time  )
					case "${level}" in
						global  ) EndTime="${Content}" ;;
					esac
					;;					
            hosts   )
					case "${level}" in
						global  ) Hosts="${Content}" ;;
					esac
					;;
            port    )
					case "${level}" in
						global  ) Port="${Content}" ;;
					esac
					;;
			severity )
					case "${level}" in
						global  ) Severity="${Content}" ;;
					esac
					;;
			new_severity )
					case "${level}" in
						global  ) NewSeverity="${Content}" ;;
					esac
					;;
			name )
					case "${level}" in
						nvt  ) Severity="${Content}" ;;
					esac
					;;
		esac
	done < <($omp -iX '<get_overrides details="1"/>')
}

set_credentials() {
	local ReferencePrefix='credential'
	local ReferenceCounter=
	local ImportStatus=0
	local Name=
	local Exists=
	local ExistingName=
	local level=
	declare -gA Credentials

	echo "Checking credentials"
	while read line
	do
		ReferenceCounter="${line%%@*}"
		Name="${line#*@}"
		Exists=0
		while parse_xml ; do
			case ${Tag} in
				lsc_credential  )
						ReferenceUUID="${Attribute[id]}"
						ExistingName=
						level='global'
						;;
				/lsc_credential )
						if [[ "${Name}" == "${ExistingName}" ]] ; then
							Credentials[${ReferenceCounter}]="${ReferenceUUID}"							
							Exists=1
						fi
						;;
				owner   ) level='owner' ;;
				/owner  ) level='global' ;;
				permissions  ) level='permissions' ;;
				/permissions ) level='global' ;;
				name    )  
						case "${level}" in
							global    ) ExistingName="${Content}" ;;
						esac
						;;
			esac
		done < <($omp -iX '<get_lsc_credentials/>')
		if [[ ${Exists} -eq 0 ]] ; then
			error "Credential ${ReferenceCounter} (${Name}) not found, you have to add it by hand"
			ImportStatus=1
		fi
	done < <(egrep "^${ReferencePrefix}_?" "${TmpDir}/${DumpFile}.cfg"|cut -d_ -f2-)
	if [[ ${ImportStatus} -eq 1 ]] ; then
		exit 1
	fi
}

set_filters() {
	local ReferencePrefix='filter'
	local ReferenceCounter=
	local ImportStatus=0
	local Name=
	local level=
	declare -gA Filters
	declare -A ExistsList

	echo "Importing filters"
	while parse_xml ; do
		case ${Tag} in
			filter  )
					ReferenceUUID="${Attribute[id]}"
					Name=
					level='global'
					;;
			/filter )
					ExistsList[${Name}]="${ReferenceUUID}"
					;;
			owner   ) level='owner' ;;
			/owner  ) level='global' ;;
			permissions  ) level='permissions' ;;
			/permissions ) level='global' ;;
			name    )  
					case "${level}" in
						global    ) Name="${Content}" ;;
					esac
					;;
		esac
	done < <($omp -iX '<get_filters/>')
	while read line
	do
		ReferenceCounter="${line%%@*}"
		Name="${line#*@}"
		if in_array "${Name}" "${!ExistsList[@]}" ; then
			echo " - ${ReferencePrefix} '${Name}' already exists, skipping import"
			Filters[${ReferenceCounter}]="${ExistsList[$Name]}"							
		else
			while parse_xml ; do
				case ${Tag} in
					create_filter_response )
						if [[ ${Attribute[status]} -eq 201 ]] ; then
							echo " - imported $Name as ${Attribute[id]}"
							Filters[${ReferenceCounter}]="${Attribute[id]}"
						else
							error "Could not import ${ReferencePrefix} ${ReferenceCounter} (${Name}), status returned was '${Attribute[status]}'"
							ImportStatus=1
						fi
						;;
				esac
			done < <($omp -iX - <"${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
		fi
	done < <(egrep "^${ReferencePrefix}_?" "${TmpDir}/${DumpFile}.cfg"|cut -d_ -f2-)
	if [[ ${ImportStatus} -eq 1 ]] ; then
		exit 1
	fi
}

set_report_formats() {
	local ReferencePrefix='reportformat'
	local ReferenceCounter=
	local ReferenceUUID=
	local ImportStatus=0
	local Name=
	local level=
	declare -gA ReportFormats
	declare -A ExistsList

	echo "Importing report formats"
	while parse_xml ; do
		case ${Tag} in
			report_format  )
					ReferenceUUID="${Attribute[id]}"
					Name=
					level='global'
					;;
			/report_format )
					ExistsList[${Name}]="${ReferenceUUID}"
					;;
			owner   ) level='owner' ;;
			/owner  ) level='global' ;;
			permissions  ) level='permissions' ;;
			/permissions ) level='global' ;;
			name    )  
					case "${level}" in
						global    ) Name="${Content}" ;;
					esac
					;;
		esac
	done < <($omp -iX '<get_report_formats/>')
	while read line
	do
		ReferenceCounter="${line%%@*}"
		Name="${line#*@}"
		if in_array "${Name}" "${!ExistsList[@]}" ; then
			echo " - ${ReferencePrefix} '${Name}' already exists, skipping import"
			ReportFormats[${ReferenceCounter}]="${ExistsList[$Name]}"							
			printf "<modify_report_format report_format_id='%s'><active>%s</active></modify_report_format>" \
			"${ReferenceUUID}" "1" | $omp -iX - >/dev/null
		else
			while parse_xml ; do
				case ${Tag} in
					create_report_format_response )
						if [[ ${Attribute[status]} -eq 201 ]] ; then
							echo " - imported $Name as ${Attribute[id]}"
							ReportFormats[${ReferenceCounter}]="${Attribute[id]}"
							printf "<modify_report_format report_format_id='%s'><active>%s</active></modify_report_format>" \
							"${Attribute[id]}" "1" | $omp -iX - >/dev/null
						else
							error "Could not import ${ReferencePrefix} ${ReferenceCounter} (${Name}), status returned was '${Attribute[status]}'"
							ImportStatus=1
						fi
						;;
				esac
			done < <($omp -iX - <"${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
		fi
	done < <(egrep "^${ReferencePrefix}_?" "${TmpDir}/${DumpFile}.cfg"|cut -d_ -f2-)
	if [[ ${ImportStatus} -eq 1 ]] ; then
		exit 1
	fi
}

set_scan_config() {
	local ReferencePrefix='scanconfig'
	local ReferenceCounter=
	local ReferenceUUID=
	local ImportStatus=0
	local Name=
	local level=
	declare -gA ScanConfigs
	declare -A ExistsList

	echo "Importing scan configurations"
	while parse_xml ; do
		case ${Tag} in
			config  )
					ReferenceUUID="${Attribute[id]}"
					Name=
					level='global'
					;;
			/config )
					ExistsList[${Name}]="${ReferenceUUID}"
					;;
			owner   ) level='owner' ;;
			/owner  ) level='global' ;;
			permissions  ) level='permissions' ;;
			/permissions ) level='global' ;;
			name    )  
					case "${level}" in
						global    ) Name="${Content}" ;;
					esac
					;;
		esac
	done < <($omp -iX '<get_configs/>')
	while read line
	do
		ReferenceCounter="${line%%@*}"
		Name="${line#*@}"
		if in_array "${Name}" "${!ExistsList[@]}" ; then
			echo " - ${ReferencePrefix} '${Name}' already exists, skipping import"
			ScanConfigs[${ReferenceCounter}]="${ExistsList[$Name]}"							
		else
			while parse_xml ; do
				case ${Tag} in
					create_config_response )
						if [[ ${Attribute[status]} -eq 201 ]] ; then
							echo " - imported $Name as ${Attribute[id]}"
							ScanConfigs[${ReferenceCounter}]="${Attribute[id]}"
						else
							error "Could not import scan configuration ${ReferenceCounter} (${Name}), status returned was '${Attribute[status]}'"
							ImportStatus=1
						fi
						;;
				esac
			done < <($omp -iX - <"${TmpDir}/${DumpFile}_scan_config_${ReferenceCounter}.xml")
		fi
	done < <(egrep "^${ReferencePrefix}_?" "${TmpDir}/${DumpFile}.cfg"|cut -d_ -f2-)
	if [[ ${ImportStatus} -eq 1 ]] ; then
		exit 1
	fi
}

set_slaves() {
	local ReferencePrefix='slave'
	local ReferenceCounter=
	local ReferenceUUID=
	local ImportStatus=0
	local Name=
	local level=
	declare -gA Slaves
	declare -A ExistsList

	echo "Importing slaves"
	while parse_xml ; do
		case ${Tag} in
			slave  )
					ReferenceUUID="${Attribute[id]}"
					Name=
					level='global'
					;;
			/slave )
					ExistsList[${Name}]="${ReferenceUUID}"
					;;
			owner   ) level='owner' ;;
			/owner  ) level='global' ;;
			permissions  ) level='permissions' ;;
			/permissions ) level='global' ;;
			name    )  
					case "${level}" in
						global    ) Name="${Content}" ;;
					esac
					;;
		esac
	done < <($omp -iX '<get_slaves/>')	
	while read line
	do
		ReferenceCounter="${line%%@*}"
		Name="${line#*@}"
		if in_array "${Name}" "${!ExistsList[@]}" ; then
			echo " - ${ReferencePrefix} '${Name}' already exists, skipping import"
			Slaves[${ReferenceCounter}]="${ExistsList[$Name]}"							
		else
			while parse_xml ; do
				case ${Tag} in
					create_slave_response )
						if [[ ${Attribute[status]} -eq 201 ]] ; then
							echo " - imported $Name as ${Attribute[id]}"
							Slaves[${ReferenceCounter}]="${Attribute[id]}"
						else
							error "Could not import ${ReferencePrefix} ${ReferenceCounter} (${Name}), status returned was '${Attribute[status]}'"
							ImportStatus=1
						fi
						;;
				esac
			done < <($omp -iX - <"${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
		fi
	done < <(egrep "^${ReferencePrefix}_?" "${TmpDir}/${DumpFile}.cfg"|cut -d_ -f2-)
	if [[ ${ImportStatus} -eq 1 ]] ; then
		exit 1
	fi
}

set_alerts() {
	local ReferencePrefix='alert'
	local ReferenceCounter=
	local ReferenceUUID=
	local ImportStatus=0
	local replaceindex=
	local Name=
	local level=
	declare -gA Alerts
	declare -A ExistsList

	echo "Importing alerts"
	while parse_xml ; do
		case ${Tag} in
			alert  )
					ReferenceUUID="${Attribute[id]}"
					Name=
					level='global'
					;;
			/alert )
					ExistsList[${Name}]="${ReferenceUUID}"
					;;
			owner         ) level='owner' ;;
			permissions   ) level='permissions' ;;
			condition     ) level='condition' ;;
			event         ) level='event' ;;
			method        ) level='method' ;;
			/owner        ) level='global' ;;
			/permissions  ) level='global' ;;
			/condition    ) level='global' ;;
			/event        ) level='global' ;;
			/method       ) level='global' ;;
			name    )  
					case "${level}" in
						global    ) Name="${Content}" ;;
					esac
					;;
		esac
	done < <($omp -iX '<get_alerts/>')	
	while read line
	do
		ReferenceCounter="${line%%@*}"
		Name="${line#*@}"
		if in_array "${Name}" "${!ExistsList[@]}" ; then
			echo " - ${ReferencePrefix} '${Name}' already exists, skipping import"
			Alerts[${ReferenceCounter}]="${ExistsList[$Name]}"							
		else
			for replacestring in $(egrep -o "filter_[[:digit:]]+" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
			do
				replaceindex="${replacestring#*_}"
				sed -i "s/${replacestring}/${Filters[$replaceindex]}/g" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml"
			done
			for replacestring in $(egrep -o "reportformat_[[:digit:]]+" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
			do
				replaceindex="${replacestring#*_}"
				sed -i "s/${replacestring}/${ReportFormats[$replaceindex]}/g" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml"
			done
			while parse_xml ; do
				case ${Tag} in
					create_alert_response )
						if [[ ${Attribute[status]} -eq 201 ]] ; then
							echo " - imported $Name as ${Attribute[id]}"
							Alerts[${ReferenceCounter}]="${Attribute[id]}"
						else
							error "Could not import ${ReferencePrefix} ${ReferenceCounter} (${Name}), status returned was '${Attribute[status]}'"
							ImportStatus=1
						fi
						;;
				esac
			done < <($omp -iX - <"${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
		fi
	done < <(egrep "^${ReferencePrefix}_?" "${TmpDir}/${DumpFile}.cfg"|cut -d_ -f2-)
	if [[ ${ImportStatus} -eq 1 ]] ; then
		exit 1
	fi
}

set_schedules() {
	local ReferencePrefix='schedule'
	local ReferenceCounter=
	local ReferenceUUID=
	local ImportStatus=0
	local Name=
	local level=
	declare -gA Schedules
	declare -A ExistsList

	echo "Importing schedules"
	while parse_xml ; do
		case ${Tag} in
			schedule  )
					ReferenceUUID="${Attribute[id]}"
					Name=
					level='global'
					;;
			/schedule )
					ExistsList[${Name}]="${ReferenceUUID}"
					;;
			owner             ) level='owner' ;;
			permissions       ) level='permissions' ;;
			simple_period     ) level='period' ;;
			simple_duration   ) level='duration' ;;
			/owner            ) level='global' ;;
			/permissions      ) level='global' ;;
			/simple_duration  ) level='global' ;;
			/simple_period    ) level='global' ;;
			name    )  
					case "${level}" in
						global    ) Name="${Content}" ;;
					esac
					;;
		esac
	done < <($omp -iX '<get_schedules/>')
	while read line
	do
		ReferenceCounter="${line%%@*}"
		Name="${line#*@}"
		if in_array "${Name}" "${!ExistsList[@]}" ; then
			echo " - ${ReferencePrefix} '${Name}' already exists, skipping import"
			Schedules[${ReferenceCounter}]="${ExistsList[$Name]}"							
		else
			while parse_xml ; do
				case ${Tag} in
					create_schedule_response )
						if [[ ${Attribute[status]} -eq 201 ]] ; then
							echo " - imported $Name as ${Attribute[id]}"
							Schedules[${ReferenceCounter}]="${Attribute[id]}"
						else
							error "Could not import ${ReferencePrefix} ${ReferenceCounter} (${Name}), status returned was '${Attribute[status]}'"
							ImportStatus=1
						fi
						;;
				esac
			done < <($omp -iX - <"${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
		fi
	done < <(egrep "^${ReferencePrefix}_?" "${TmpDir}/${DumpFile}.cfg"|cut -d_ -f2-)
	if [[ ${ImportStatus} -eq 1 ]] ; then
		exit 1
	fi
}

set_targets() {
	local ReferencePrefix='target'
	local ReferenceCounter=
	local ReferenceUUID=
	local ImportStatus=0
	local replaceindex=
	local Name=
	local level=
	declare -gA Targets
	declare -A ExistsList

	echo "Importing targets"
	while parse_xml ; do
		case ${Tag} in
			target  )
					ReferenceUUID="${Attribute[id]}"
					Name=
					level='global'
					;;
			/target )
					ExistsList[${Name}]="${ReferenceUUID}"
					;;
			owner               ) level='owner' ;;
			permissions         ) level='permissions' ;;
			ssh_lsc_credential  ) level='sshcredential' ;;
			smb_lsc_credential  ) level='smbcredential' ;;
			esxi_lsc_credential ) level='esxicredential' ;;
			port_list           ) level='portlist' ;;
			/owner              ) level='global' ;;
			/permissions        ) level='global' ;;
			/ssh_lsc_credential ) level='global' ;;
			/smb_lsc_credential ) level='global' ;;
			/esxi_lsc_credential ) level='global' ;;
			/port_list          ) level='global' ;;
			name    )  
					case "${level}" in
						global    ) Name="${Content}" ;;
					esac
					;;
		esac
	done < <($omp -iX '<get_targets/>')
	while read line
	do
		ReferenceCounter="${line%%@*}"
		Name="${line#*@}"
		if in_array "${Name}" "${!ExistsList[@]}" ; then
			echo " - ${ReferencePrefix} '${Name}' already exists, skipping import"
			Targets[${ReferenceCounter}]="${ExistsList[$Name]}"							
		else
			for replacestring in $(egrep -o "credential_[[:digit:]]+" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
			do
				replaceindex="${replacestring#*_}"
				sed -i "s/${replacestring}/${Credentials[$replaceindex]}/g" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml"
			done
			while parse_xml ; do
				case ${Tag} in
					create_target_response )
						if [[ ${Attribute[status]} -eq 201 ]] ; then
							echo " - imported $Name as ${Attribute[id]}"
							Targets[${ReferenceCounter}]="${Attribute[id]}"
						else
							error "Could not import ${ReferencePrefix} ${ReferenceCounter} (${Name}), status returned was '${Attribute[status]}'"
							ImportStatus=1
						fi
						;;
				esac
			done < <($omp -iX - <"${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
		fi
	done < <(egrep "^${ReferencePrefix}_?" "${TmpDir}/${DumpFile}.cfg"|cut -d_ -f2-)
	if [[ ${ImportStatus} -eq 1 ]] ; then
		exit 1
	fi	
}

set_tasks() {
	local ReferencePrefix='task'
	local ReferenceCounter=
	local ReferenceUUID=
	local ImportStatus=0
	local replaceindex=
	local Name=
	local level=
	declare -gA Tasks
	declare -A ExistsList

	echo "Importing tasks"
	while parse_xml ; do
		case ${Tag} in
			task  )
					ReferenceUUID="${Attribute[id]}"
					Name=
					level='global'
					;;
			/task )
					ExistsList[${Name}]="${ReferenceUUID}"
					;;
			owner               ) level='owner' ;;
			permissions         ) level='permissions' ;;
			config              ) level='scanconfig' ;;
			target              ) level='target' ;;
			scanner             ) level='scanner' ;;
			slave               ) level='slave' ;;
			schedule            ) level='schedule' ;;
			current_report      ) level='currentreport' ;;
			first_report        ) level='firstreport' ;;
			last_report         ) level='lastreport' ;;
			second_last_report  ) level='2ndlastreport' ;;
			alert               ) level='alert' ;;
			preference          ) level='preference' ;;
			/owner              ) level='global' ;;
			/permissions        ) level='global' ;;
			/config             ) level='global' ;;
			/target             ) level='global' ;;
			/scanner            ) level='global' ;;
			/slave              ) level='global' ;;
			/schedule           ) level='global' ;;
			/current_report     ) level='global' ;;
			/first_report       ) level='global' ;;
			/last_report        ) level='global' ;;
			/second_last_report ) level='global' ;;
			/alert              ) level='global' ;;
			/preference         ) level='global' ;;
			name    )  
					case "${level}" in
						global    ) Name="${Content}" ;;
					esac
					;;
		esac
	done < <($omp -iX '<get_tasks/>')
	while read line
	do
		ReferenceCounter="${line%%@*}"
		Name="${line#*@}"
		if in_array "${Name}" "${!ExistsList[@]}" ; then
			echo " - ${ReferencePrefix} '${Name}' already exists, skipping import"
			Tasks[${ReferenceCounter}]="${ExistsList[$Name]}"							
		else
			for replacestring in $(egrep -o "scanconfig_[[:digit:]]+" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
			do
				replaceindex="${replacestring#*_}"
				sed -i "s/${replacestring}/${ScanConfigs[$replaceindex]}/g" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml"
			done
			for replacestring in $(egrep -o "target_[[:digit:]]+" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
			do
				replaceindex="${replacestring#*_}"
				sed -i "s/${replacestring}/${Targets[$replaceindex]}/g" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml"
			done
			for replacestring in $(egrep -o "slave_[[:digit:]]+" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
			do
				replaceindex="${replacestring#*_}"
				sed -i "s/${replacestring}/${Slaves[$replaceindex]}/g" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml"
			done
			for replacestring in $(egrep -o "schedule_[[:digit:]]+" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
			do
				replaceindex="${replacestring#*_}"
				sed -i "s/${replacestring}/${Schedules[$replaceindex]}/g" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml"
			done
			for replacestring in $(egrep -o "alert_[[:digit:]]+" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
			do
				replaceindex="${replacestring#*_}"
				sed -i "s/${replacestring}/${Alerts[$replaceindex]}/g" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml"
			done
			while parse_xml ; do
				case ${Tag} in
					create_task_response )
						if [[ ${Attribute[status]} -eq 201 ]] ; then
							echo " - imported $Name as ${Attribute[id]}"
							Tasks[${ReferenceCounter}]="${Attribute[id]}"
						else
							error "Could not import ${ReferencePrefix} ${ReferenceCounter} (${Name}), status returned was '${Attribute[status]}'"
							ImportStatus=1
						fi
						;;
				esac
			done < <($omp -iX - <"${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
		fi
	done < <(egrep "^${ReferencePrefix}_?" "${TmpDir}/${DumpFile}.cfg"|cut -d_ -f2-)
	if [[ ${ImportStatus} -eq 1 ]] ; then
		exit 1
	fi	
}

set_notes() {
	local ReferencePrefix='note'
	local ReferenceCounter=
	local ReferenceUUID=
	local ImportStatus=0
	local replaceindex=
	local Name=
	local level=
	declare -gA Notes
	declare -A ExistsList

	echo "Importing notes"
	while parse_xml ; do
		case ${Tag} in
			note  )
					ReferenceUUID="${Attribute[id]}"
					Name=
					level='global'
					;;
			/note )
					ExistsList[${Name}]="${ReferenceUUID}"
					;;
			owner               ) level='owner' ;;
			permissions         ) level='permissions' ;;
			nvt                 ) level='nvt' ;;
			task                ) level='task' ;;
			text                ) level='text' ;;
			result              ) level='result' ;;
			/owner              ) level='global' ;;
			/permissions        ) level='global' ;;
			/nvt                ) level='global' ;;
			/task               ) level='global' ;;
			/result             ) level='global' ;;
			/text               ) level='global' ;;
			name    )
					case "${level}" in
						nvt  ) Severity="${Content}" ;;
					esac
					;;
		esac
	done < <($omp -iX '<get_notes/>')
	while read line
	do
		ReferenceCounter="${line%%@*}"
		Name="${line#*@}"
		if in_array "${Name}" "${!ExistsList[@]}" ; then
			echo " - ${ReferencePrefix} '${Name}' already exists, skipping import"
			Notes[${ReferenceCounter}]="${ExistsList[$Name]}"							
		else
			for replacestring in $(egrep -o "task_[[:digit:]]+" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
			do
				replaceindex="${replacestring#*_}"
				sed -i "s/${replacestring}/${Tasks[$replaceindex]}/g" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml"
			done
			sed -i 's/#n/\n/g' "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml"
			while parse_xml ; do
				case ${Tag} in
					create_note_response )
						if [[ ${Attribute[status]} -eq 201 ]] ; then
							echo " - imported $Name as ${Attribute[id]}"
							Notes[${ReferenceCounter}]="${Attribute[id]}"
						else
							error "Could not import ${ReferencePrefix} ${ReferenceCounter} (${Name}), status returned was '${Attribute[status]}'"
							ImportStatus=1
						fi
						;;
				esac
			done < <($omp -iX - <"${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
		fi
	done < <(egrep "^${ReferencePrefix}_?" "${TmpDir}/${DumpFile}.cfg"|cut -d_ -f2-)
	if [[ ${ImportStatus} -eq 1 ]] ; then
		exit 1
	fi	
}

set_overrides() {
	local ReferencePrefix='override'
	local ReferenceCounter=
	local ReferenceUUID=
	local ImportStatus=0
	local replaceindex=
	local Name=
	local level=
	declare -gA Overrides
	declare -A ExistsList

	echo "Importing overrides"
	while parse_xml ; do
		case ${Tag} in
			override  )
					ReferenceUUID="${Attribute[id]}"
					Name=
					level='global'
					;;
			/override )
					ExistsList[${Name}]="${ReferenceUUID}"
					;;
			owner               ) level='owner' ;;
			permissions         ) level='permissions' ;;
			nvt                 ) level='nvt' ;;
			task                ) level='task' ;;
			text                ) level='text' ;;
			result              ) level='result' ;;
			/owner              ) level='global' ;;
			/permissions        ) level='global' ;;
			/nvt                ) level='global' ;;
			/task               ) level='global' ;;
			/result             ) level='global' ;;
			/text               ) level='global' ;;
			name    )
					case "${level}" in
						nvt  ) Severity="${Content}" ;;
					esac
					;;
		esac
	done < <($omp -iX '<get_overrides/>')
	while read line
	do
		ReferenceCounter="${line%%@*}"
		Name="${line#*@}"
		if in_array "${Name}" "${!ExistsList[@]}" ; then
			echo " - ${ReferencePrefix} '${Name}' already exists, skipping import"
			Overrides[${ReferenceCounter}]="${ExistsList[$Name]}"							
		else
			for replacestring in $(egrep -o "task_[[:digit:]]+" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
			do
				replaceindex="${replacestring#*_}"
				sed -i "s/${replacestring}/${Tasks[$replaceindex]}/g" "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml"
			done
			sed -i 's/#n/\n/g' "${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml"
			while parse_xml ; do
				case ${Tag} in
					create_override_response )
						if [[ ${Attribute[status]} -eq 201 ]] ; then
							echo " - imported $Name as ${Attribute[id]}"
							Overrides[${ReferenceCounter}]="${Attribute[id]}"
						else
							error "Could not import ${ReferencePrefix} ${ReferenceCounter} (${Name}), status returned was '${Attribute[status]}'"
							ImportStatus=1
						fi
						;;
				esac
			done < <($omp -iX - <"${TmpDir}/${DumpFile}_${ReferencePrefix}_${ReferenceCounter}.xml")
		fi
	done < <(egrep "^${ReferencePrefix}_?" "${TmpDir}/${DumpFile}.cfg"|cut -d_ -f2-)
	if [[ ${ImportStatus} -eq 1 ]] ; then
		exit 1
	fi	
}

#===============================================================================
# Main
#===============================================================================
initialize
parse_args "$@" # parses any args passed

if [[ -z ${Action} ]] ; then
	error "-a is required"
	exit 1
fi
if [[ -z ${DumpFile} ]] ; then
	error "-f is required"
	exit 1
fi

case "${Action}" in
	export )
### get_portlists * for now we will just use the defaults
	get_credentials
### get_credentials_smb 
	get_filters
	get_report_formats
	get_scan_config
	get_slaves
	get_schedules
		get_alerts
		get_targets 
			get_tasks
				get_notes
				get_overrides
	 
	# get_users
	# get_groups
	# get_roles
	pack
	;;
	import )
	if [[ ! -f ${BaseDir}/${DumpFile}.tgz || ! -f ${DumpFile}.tgz ]] ; then
		error "${DumpFile}.tgz not found"
		exit 1
	fi
	unpack
	empty_trashcan
	set_credentials
	set_filters
	set_report_formats
	set_scan_config
	set_slaves
	set_schedules
		set_alerts
		set_targets 
			set_tasks
				set_notes
				set_overrides

	;;
esac
