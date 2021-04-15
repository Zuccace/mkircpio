#!/bin/bash

helpscreen() {

	cat <<- endhelp
		$(realpath "$0") usage.

		Varsion 0.0.1alpha - "very beta"
		
		Takes a list (\\n seperated) of files,
		directories, kernel modules and firmware files
		from standard input and packs all them into a
		cpio archive for use as an initramfs.
		Using --output <output cpio> the destination for the
		cpio can be chosen.

		If a directory is given its content will be copied
		to the _root_ of the cpio.
		This way the whole content of a initramfs can reside
		in a single directory of a running system.

		Files given should have an absolute path.
		If a dynamic binary is encountered, then all the
		required libraries will be automatically included too.
		If a C++ binary is listed, it _might_ require
		a manual addition of C++ standard library. Yes, it's a bug.

		Kernel modules can be given by its name or
		with absolute path.
		If given the absolute path the module _will_ retain
		the same path inside the cpio.
		Using absolute paths for kernel modules is discouraged.
		With '--auto-firmware' _all_ the firmaware files
		listed in modinfo will be added into the cpio.
		Using --auto-firmware can add several non-required
		firmware files to the cpio, and is thus disabled by default.
		The --kver <kernel version> can be used to override
		the default 'uname -r' ($(uname -r))
		kernel version.
		
		Firware files can be added using absolute path or
		relative to ${firmwaredir}.

		This script does _not_ provide any premade or automatic
		generation of init/linuxrc script which is needed to
		boot the system from initramfs.
		
endhelp
}

confdir="/etc/cinitramfs"
extrafilesdir="${confdir}/root"
filelist="${confdir}/files"
modulelist="${confdir}/modules"
firmwarelist="${confdir}/firmwares"

firmwaredir="/lib/firmware"
cpiocmd=(cpio --create --format=newc)
compressor=(pigz -11 --iterations 16 --maxsplits 8 --blocksize 1024 --stdout --keep)
#compressor=(gzip --best --stdout)
modprinter=(awk -v "d=${firmwaredir}" '(index($1,d) != 1)')
declare -A modarr

msg() {
	echo -e "$*" 1>&2
}

# Display error message and exit.
err() {
	local e
	if [[ "$1" =~ ^[0-9]+$ ]]
	# If $1 is a number, then use it as an exit code.
	then
		e="$1"
		shift
	else
		e=1
	fi
	[[ "$*" ]] && msg "$*"
	msg "Aborting. Error code: $e"
	exit "$e"
}

# Like 'sort | uniq' but does not change the order
# and can output lines right after they arrive
# since there's no sorting of lines.
awkuniq() {
	awk '(!seen[$0]++)'
}

unterminator() {
	# FIXME: Make this function work on any cpio archive format.
	# Might need to discard bbe for something else.
	bbe -b '/07070100000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000B00000000TRAILER!!!/:$' -e D
}

# Reads filenames from stdin,
# checks if the said file is a symlink,
# resolves the symlink, chain possibly,
# while printing all the symlinks and
# the the last component (the file).
# Input and output (stdout) uses
# _newline_ to seperate filenames.
printfilelinks() {
	local f
	local l
	awkuniq | while read f
	do
		if [[ -f "$f" ]]
		then
			echo "$f"
			while [[ -L "$f" ]]
			do
				l="$(readlink "$f")"
				if [[ "${l:0:1}" != "/" ]]
				then
					f="$(realpath "$(dirname "$f")/${l}")"
				else
					f="$l"
				fi
				echo "$f"
			done
		else
			msg "Missing file: $f"
		fi
	done | awkuniq
}

# Reads filenames from stdin,
# and passes them to ldd.
# awk does its magic to extract filenames
# from ldd output.
# output is stdout.
filelister() {
	# tee copies the stream for ldd and
	# as an unmodified list for printfilelinks.
	# We use this technique to avoid the very rare case
	# of only one file being supplied for ldd.
	# ldd does not print out the file name
	# being examined if there's only one file passed.
	sed -e 's/ \+/\n/g' | tee >(
		xargs --no-run-if-empty ldd 2> /dev/null | awk '{
			if ($2 == "=>") print $3
			else if (!$2) {
				if (substr($1,length($1)) == ":") next # tee above already handles these
				print $1
			} else if (!$3 && substr($1,1,1) == "/") print $1
		}'
	) | awk -v "firmwaredir=${firmwaredir}" '{ if (substr($1,1,1) != "/") $1 = firmwaredir "/" $1; print $1 }' | printfilelinks
}

# Reads module names from stdin.
# Outputs a list of modules
# with full paths and their dependencies.
modulelister() {
	local module
	local deparr
	local modules
	declare -a modules deparr
	deparr=()
	local p v e
	# ^ Parameter, value, extra data
	
	{
		while read p v e
		do
			case "${p%:}" in
				"filename")
					[[ "$v" != "(builtin)" ]] && echo "$v"
				;;
				"depends")
					modules=(${v//,/ })
					for module in "${modules[@]}"
					do
						[[ "${modarr["$module"]}" ]] || deparr+=("$module")
					done
				;;
				"softdep")
					modules=(${e//platform:/})
					for module in "${modules[@]}"
					do
						[[ "${modarr["$module"]}" ]] || deparr+=("$module")
					done
				;;
				"firmware")
					echo "${firmwaredir}/$v"
				;;
				"name")
					modarr+=(["$v"]=true)
				;;
			esac
		done < <(xargs --no-run-if-empty modinfo --set-version="${kver:="$(uname -r)"}" 2>&1)

		[[ "${#deparr[@]}" -gt 0 ]] && modulelister <<< "${deparr[@]}"
		
	} | "${modprinter[@]}" | printfilelinks
}

# Reads files from stdin.
# Prints out the same files but also the
# parent directories in right order for cpio.
dirinsert() {
	awk '
		BEGIN {
			FS="/"
		}
		{
			if ($1 == "") start=2
			else start=1
			p=""
			for (i=start; i<NF; i++) {
				p = p "/" $i
				if (!seen[p]++) print p
			} print $0
		}
	'
}

# The main function.
list2cpio() {
	local f
	local dirlist
	declare -a dirlist
	
	# Adds directories to directory list.
	# Send rest to 'tee' for splitting to files and modules/firmwares
	while read f
	do
		if [[ -d "$f" ]]
		then
			if [[ ! -n "$(find "${f}" -prune -empty -type d 2>/dev/null)" ]]
			then
				dirlist+=("$f")
				msg "Adding directory: $f"
			else
				msg "Skipping empty dir: ${f}"
			fi
		else
			echo "$f"
		fi
	done > >(
			{
				tee \
					>(egrep '^/|^.+\.[^/\.]+$' | filelister) \
					>(egrep '^[^/\.]+$' | modulelister) > /dev/null
			} | dirinsert | "${cpiocmd[@]}" | unterminator
			
		)

	wait # for all the subshells to finish.

	
		
	local d
	if [[ "${#dirlist[@]}" = 0 ]]
	then
		if [[ -d "$extrafilesdir" && ! -n "$(find "${extrafilesdir}" -prune -empty -type d 2>/dev/null)" ]]
		then
			find "${extrafilesdir}" -printf '%P\n' | "${cpiocmd[@]}" --directory="${extrafilesdir}"
		fi
	elif [[ "${#dirlist[@]}" = 1 ]]
	then
		find "${dirlist}" -printf '%P\n' | "${cpiocmd[@]}" --directory="${dirlist}"
	else
		local lastdir="${dirlist[$((${#dirlist[@]}-1))]}"
		for d in "${dirlist[@]}"
		do
			[[ "$d" = "$lastdir" ]] && break
			find "${d}" -printf '%P\n' | "${cpiocmd[@]}" --directory="${d}" | unterminator
		done
		find "${lastdir}" -printf '%P\n' | "${cpiocmd[@]}" --directory="${lastdir}"
	fi
}

if ! which bbe &> /dev/null
then
	err 3 "'bbe' is required."

elif [[ -z "$1" ]]
then
	msg "You need --help."
	err

elif [[ $2 && "${1:0:1}" != "-" && "${2:0:1}" != "-" ]]
then
	# Compability mode with /sbin/installkernel
	# scripts in /etc/kernel/postinst.d/
	kver="$1"
	destdir="$(dirname "$2")"
	output="${destdir%/}/initc-${kver}.img"
	if [[ -r "/etc/kernel/initc.lst" ]]
	then
		egrep --no-filename --invert-match '^([[:space:]]*#|$)' /etc/kernel/initc.lst 2> /dev/null | \
			list2cpio | "${compressor[@]}" > "${output}"
	else
		echo "file /etc/kernel/initc.lst does not exist or isn't readable"
	fi
	
elif [[ $1 && ${1:0:1} != "-" ]]
then
	msg "Non option argument: ${1}\n"
	helpscreen
	err
else
	while [[ "${1:0:2}" = "--" ]]
	do
		case "$1" in
			"--output")
				outputdir="$(dirname "$2")"
				if [[ -d "$outputdir" ]]
				then
					output="$2"
					shift
				else
					err 15 "No such directory: ${outputdir}"
				fi
			;;
			"--auto-firmware")
				modprinter=("cat")		
			;;
			"--verbose")
				cpiocmd+=(--verbose)
				verbose=1
			;;
			"--compressor")
				shift
				compressor=()
				
				while [[ "$1" && "$1" != "--" ]]
				do
					compressor+=("$1")
					shift
				done
				
				continue # Avoid shifting.
			;;
			"--help")
				helpscreen
				exit 0
			;;
			*)
				msg "Unknown switch: $1"
				helpscreen
				err
			;;
		esac
		shift
	done
	
	if [[ "$output" ]]
	then
		list2cpio | "${compressor[@]}" > "${output}"
	else
		list2cpio | "${compressor[@]}"
	fi
fi
