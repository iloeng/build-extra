#!/bin/sh

# This script helps Git for Windows developers to manage their Pacman
# repository and their local pacman package-database.
#
# A Pacman repository is like a Git repository, but for binary packages.
#
# This script supports seven commands:
#
# - 'fetch' to initialize (or update) a local mirror of the Pacman repository
#
# - 'add' to add packages to the local mirror
#
# - 'remove' to make the next 'push' skip the given package(s)
#
# - 'push' to synchronize local changes (after calling `repo-add`) to the
#   remote Pacman repository
#
# - 'files' shows files that are not owned by any package.
#
# - 'dirs' shows directories that are not owned by any package.
#
# - 'orphans' removes any package that became an orphan.

die () {
	format="$1\\n"; shift
	printf "$format" "$@" >&2
	exit 1
}

mode=
case "$1" in
lock|unlock|break_lock|quick_add)
	mode="$1"
	shift
	;;
*)
	die "Usage:\n%s\n%s\n" \
		" $0 quick_add <package>..." \
		" $0 ( lock | unlock <id> | break_lock )"
	;;
esac

case "$(uname -s)" in
MSYS|MINGW*)
	# MSYS2's mingw-w64-$arch-ca-certificates seem to lag behind ca-certificates
	CURL_CA_BUNDLE=/usr/ssl/certs/ca-bundle.crt
	export CURL_CA_BUNDLE

	this_script_dir="$(cygpath -am "${0%/*}")"
	;;
*)
	this_script_dir="$(cd "$(dirname "$0")" && pwd -P)"
	;;
esac
base_url=https://wingit.blob.core.windows.net
mirror=/var/local/pacman-mirror

architectures="i686 x86_64 aarch64"

arch_dir () { # <architecture>
	echo "$mirror/$1"
}

map_arch () { # <architecture>
	# Azure Blobs does not allow underlines, but dashes in container names
	case "$1" in
	x86_64) echo "x86-64";;
	clang-aarch64) echo "aarch64";;
	*) echo "$1";;
	esac
}

arch_url () { # <architecture>
	echo "$base_url/$(map_arch $1)"
}

arch_to_mingw () { # <arch>
	case "$arch" in
	i686) echo mingw32;;
	aarch64) echo aarch64;;
	*) echo mingw64;;
	esac
}

package_list () { # db.tar.xz
	tar tf "$1" |
	sed -ne '/ /d' -e 's/\/$//p'
}

call_gpg () {
	if test -z "$CALL_GPG"
	then
		GIT_GPG_PROGRAM="$(git config gpg.program)"
		CALL_GPG="${GIT_GPG_PROGRAM:-gpg}"
	fi

	"$CALL_GPG" "$@"
}

repo_add () {
	if test ! -s "$this_script_dir/repo-add"
	then
		# Make sure that GPGKEY is used unquoted
		 sed 's/"\(\${\?GPGKEY}\?\)"/\1/g' </usr/bin/repo-add >"$this_script_dir/repo-add"
	fi &&
	"$this_script_dir/repo-add" "$@"
}

sanitize_db () { # <file>...
	perl -e '
		foreach my $path (@ARGV) {
			my @to_delete = ();
			my %base_to_date = ();
			my %base_to_full_name = ();

			open($fh, "-|", "tar", "tvf", $path) or die;
			while (<$fh>) {
				# parse lines like this:
				# drwxr-xr-x root/root         0 2019-02-17 21:45 bash -4.4.023-1 /
				if (/(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(.+)(-\d[^-]*-\d+)\/$/) {
					my $date = $4 . " " . $5;
					my $prefix = $6;
					my $full_name = $6 . $7;
					if ($prefix =~ / /) {
						push @to_delete, $full_name;
					} elsif (exists($base_to_date{$prefix})) {
						print $prefix . ": " . $base_to_date{$prefix} . " vs " . $date . "\n";
						if (($base_to_date{$prefix} cmp $date) < 0) {
							print $base_to_date{$prefix} . " older than " . $date . ": delete " . $base_to_date{$prefix} . "\n";
							push @to_delete, $base_to_full_name{$prefix};
							# replace
							$base_to_full_name{$prefix} = $full_name;
							$base_to_date{$prefix} = $date;
						} else {
							print $base_to_date{$prefix} . " younger than " . $date . ": delete " . $date . "\n";
							push @to_delete, $full_name;
						}
					} else {
						$base_to_date{$prefix} = $date;
						$base_to_full_name{$prefix} = $full_name;
					}
				}
			}
			close($fh);

			if ($#to_delete > 0) {
				@bsdtar = ("bsdtar", "-cJf", $path . ".bup");
				foreach my $item (@to_delete) {
					push @bsdtar, "--exclude";
					push @bsdtar, $item . "*";
				}
				push @bsdtar, "@" . $path;
				print "Sanitizing: " . join(" ", @bsdtar) . "\n";
				if (system(@bsdtar) == 0) {
					rename $path . ".bup", $path or die "Could not rename $path.bup to $path";
				} else {
					die "Could not run " . join(" ", @bsdtar);
				}
			}
		}
	' "$@" &&
	if test -n "$GPGKEY"
	then
		for path in "$@"
		do
			call_gpg --detach-sign --no-armor -u $GPGKEY "$path" ||
			die "Could not sign $path"
		done
	fi
}

quick_add () { # <file>...
	test $# -gt 0 ||
	die "Need at least one file"

	if test -z "$PACMANDRYRUN$azure_blobs_token"
	then
		azure_blobs_token="$(cat "$HOME"/.azure-blobs-token)" &&
		test -n "$azure_blobs_token" ||
		die "Could not read token from ~/.azure-blobs-token"
	fi

	# Create a temporary directory to work with
	dir="$(mktemp -d)" &&
	mkdir "$dir/x86_64" "$dir/aarch64" "$dir/i686" "$dir/sources" ||
	die "Could not create temporary directory"

	i686_mingw=
	i686_msys=
	aarch64_mingw=
	aarch64_msys=
	x86_64_mingw=
	x86_64_msys=
	all_files=

	# Copy the file(s) to the temporary directory, and schedule their addition to the appropriate index(es)
	for path in "$@"
	do
		file="${path##*/}"
		mingw=
		case "${path##*/}" in
		mingw-w64-*.pkg.tar.xz|mingw-w64-*.pkg.tar.zst)
			arch=${file##mingw-w64-}
			arch=${arch#clang-}
			arch=${arch%%-*}
			key=${arch}_mingw
			;;
		git-extra-*.pkg.tar.xz|git-extra-*.pkg.tar.zst)
			arch=${file%.pkg.tar.*}
			arch=${arch##*-}
			key=${arch}_mingw
			;;
		*-*.pkg.tar.xz|*-*.pkg.tar.zst)
			arch=${file%.pkg.tar.*}
			arch=${arch##*-}
			test any != "$arch" || {
				arch="$(tar Oxf "$path" .BUILDINFO |
					sed -n 's/^installed = msys2-runtime-[0-9].*-\(.*\)/\1/p')"
				test -n "$arch" ||
				die "Could not determine architecture of '$path'"
			}
			key=${arch}_msys
			;;
		*.src.tar.gz|*.src.tar.xz|*.src.tar.zst)
			arch=sources
			key=
			;;
		*.sig)
			# skip explicit signatures; we copy them automatically
			continue
			;;
		*)
			echo "Skipping unknown file: $file" >&2
			continue
			;;
		esac
		test -n "$arch" || die "Could not determine architecture for $path"
		case " $architectures sources " in
		*" $arch "*) ;;  # okay
		*) echo "Skipping file with unknown arch: $file" >&2; continue;;
		esac

		echo "Copying $file to $arch/..." >&2
		test -z "$key" || eval "$key=\$$key\\ $file"
		all_files="$all_files $arch/$file"

		cp "$path" "$dir/$arch" ||
		die "Could not copy $path to $dir/$arch"

		if test -f "$path".sig
		then
			cp "$path".sig "$dir/$arch/" ||
			die "Could not copy $path.sig to $dir/$arch"
                        all_files="$all_files $arch/$file.sig"
		elif test -n "$GPGKEY"
		then
			echo "Signing $arch/$file..." >&2
			call_gpg --detach-sign --no-armor -u $GPGKEY "$dir/$arch/$file"
			all_files="$all_files $arch/$file.sig"
		fi
	done

	# Acquire lease
	PACMAN_DB_LEASE="$(lock)" ||
	die 'Could not obtain a lock for uploading'

	# Download indexes into the temporary directory and add files
	sign_option=
	test -z "$GPGKEY" || sign_option=--sign
	dbs=
	for arch in $architectures
	do
		eval "msys=\$${arch}_msys"
		eval "mingw=\$${arch}_mingw"
		test -n "$msys$mingw" || continue

		case "$arch,$mingw" in
		*,) db2=;;
		i686,*) db2=mingw32;;
		*aarch64*) db2=clangarm64;;
		*) db2=mingw64;;
		esac
		for db in git-for-windows-$arch ${db2:+git-for-windows-$db2}
		do
			# The Pacman repository on Azure Blobs still uses the old naming scheme
			case "$db" in
			git-for-windows-$arch) remote_db=git-for-windows;;
			git-for-windows-clangarm64) remote_db=git-for-windows-aarch64;;
			*) remote_db=$db;;
			esac

			for infix in db files
			do
				file=$db.$infix.tar.xz
				remote_file=$remote_db.$infix.tar.xz

				echo "Downloading current $arch/$file..." >&2
				curl -sfo "$dir/$arch/$file" "$(arch_url $arch)/$remote_file" || return 1

				dbs="$dbs $arch/$file $arch/${file%.tar.xz}"
				if test -n "$sign_option"
				then
					curl -sfo "$dir/$arch/$file.sig" "$(arch_url $arch)/$remote_file.sig" ||
					return 1
					gpg --verify "$dir/$arch/$file.sig" ||
					die "Could not verify GPG signature: $dir/$arch/$file"

					dbs="$dbs $arch/$file.sig $arch/${file%.tar.xz}.sig"
				fi

				sanitize_db "$dir/$arch/$file" || return 1
				test ! -f "$dir/$arch/${file%.tar.xz}" ||
				sanitize_db "$dir/$arch/${file%.tar.xz}" || return 1
			done
		done
		(cd "$dir/$arch" &&
		 repo_add $sign_option git-for-windows-$arch.db.tar.xz $msys $mingw &&
		 { test ! -h git-for-windows-$arch.db || rm git-for-windows-$arch.db; } &&
		 cp git-for-windows-$arch.db.tar.xz git-for-windows-$arch.db && {
			test -z "$sign_option" || {
				{ test ! -h git-for-windows-$arch.db.sig || rm git-for-windows-$arch.db.sig; } &&
				cp git-for-windows-$arch.db.tar.xz.sig git-for-windows-$arch.db.sig
			}
		 } &&
		 if test -n "$db2"
		 then
			repo_add $sign_option git-for-windows-$db2.db.tar.xz $mingw &&
			{ test ! -h git-for-windows-$db2.db || rm git-for-windows-$db2.db; } &&
			cp git-for-windows-$db2.db.tar.xz git-for-windows-$db2.db && {
				test -z "$sign_option" || {
					{ test ! -h git-for-windows-$db2.db.sig || rm git-for-windows-$db2.db.sig; } &&
					cp git-for-windows-$db2.db.tar.xz.sig git-for-windows-$db2.db.sig
				}
			}
		 fi) ||
		die "Could not add $msys $mingw to db in $arch"
	done

	# Upload the file(s) and the appropriate index(es)
	(cd "$dir" &&
	 for path in $all_files $dbs
	 do
		# The Pacman repository on Azure Blobs still uses the old naming scheme
		remote_path="$(echo "$path" | sed \
			-e 's,/git-for-windows-\(x86_64\|aarch64\|i686\)\.,/git-for-windows.,' \
			-e 's,/git-for-windows-clangarm64\.,/git-for-windows-aarch64.,')"
		test "$path" = "$remote_path" || {
			echo "Renaming '$path' to old-style '$remote_path'..." >&2 &&
			mv -i "$path" "$remote_path" &&
			path="$remote_path"
		} ||
		die "Could not rename $path to $remote_path"

		# Upload the 64-bit database with the lease
		action=upload
		test x86_64/git-for-windows.db != $path || action="upload-with-lease ${PACMAN_DB_LEASE:-<lease>}"

		if test -n "$PACMANDRYRUN"
		then
			echo "upload: wingit-snapshot-helper.sh wingit $(map_arch ${path%%/*}) <token> $action $dir/$path" >&2
		else
			"$this_script_dir"/wingit-snapshot-helper.sh wingit $(map_arch ${path%%/*}) "$azure_blobs_token" $action "$path"
		fi ||
		die "Could not upload $path"
	 done) ||
	die "Could not upload $all_files $dbs"

	# Release the lease, i.e. finalize the transaction
	unlock "$PACMAN_DB_LEASE" ||
	die 'Could not release lock for uploading\n'
	PACMAN_DB_LEASE=

	# Remove the temporary directory
	rm -r "$dir" ||
	die "Could not remove $dir/"
}

lock () { #
	test -z "$PACMANDRYRUN" || {
		echo "upload: wingit-snapshot-helper.sh wingit x86-64 <token> lock git-for-windows.db" >&2
		return
	}

	test -n "$azure_blobs_token" || {
		azure_blobs_token="$(cat "$HOME"/.azure-blobs-token)" &&
		test -n "$azure_blobs_token" ||
		die "Could not read token from ~/.azure-blobs-token"
	}

	echo "Trying to lock for upload..." >&2
	counter=0
	while test $counter -lt 7200
	do
		"$this_script_dir"/wingit-snapshot-helper.sh wingit x86-64 \
			"$azure_blobs_token" \
			lock --duration=-1 git-for-windows.db &&
		break

		echo "Waiting 60 seconds ($counter in total so far)..." >&2
		sleep 60
		counter=$(($counter+60))
	done
}

unlock () { # <lease-ID>
	test -z "$PACMANDRYRUN" || {
		echo "upload: wingit-snapshot-helper.sh wingit x86-64 <token> unlock ${1:-<lease>} git-for-windows.db" >&2
		return
	}

	test -n "$azure_blobs_token" || {
		azure_blobs_token="$(cat "$HOME"/.azure-blobs-token)" &&
		test -n "$azure_blobs_token" ||
		die "Could not read token from ~/.azure-blobs-token"
	}

	"$this_script_dir"/wingit-snapshot-helper.sh wingit x86-64 \
		"$azure_blobs_token" unlock "$1" git-for-windows.db
}

break_lock () { #
	test -z "$PACMANDRYRUN" || {
		echo "upload: wingit-snapshot-helper.sh wingit x86-64 <token> break-lock git-for-windows.db" >&2
		return
	}

	test -n "$azure_blobs_token" || {
		azure_blobs_token="$(cat "$HOME"/.azure-blobs-token)" &&
		test -n "$azure_blobs_token" ||
		die "Could not read token from ~/.azure-blobs-token"
	}

	"$this_script_dir"/wingit-snapshot-helper.sh wingit x86-64 \
		"$azure_blobs_token" break-lock git-for-windows.db
}

"$mode" "$@"
