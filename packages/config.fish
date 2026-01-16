function fish_greeting
    echo ""
    echo " ██████╗██████╗ ██████╗  ██████╗ "
    echo "██╔════╝██╔══██╗██╔══██╗██╔════╝ "
    echo "██║     ██║  ██║██████╔╝██║  ███╗"
    echo "██║     ██║  ██║██╔══██╗██║   ██║"
    echo "╚██████╗██████╔╝██████╔╝╚██████╔╝"
    echo " ╚═════╝╚═════╝ ╚═════╝  ╚═════╝ "
    echo ""
    echo "Welcome to cdbg! (github.com/aohoyd/cdbg)"
    echo ""
end

function apk --wraps="/sbin/apk"
    # Fix apk db because of corrupted @local
	for package in (sed -n '/@local/{s/=.*//;p}' /etc/apk/world)
        sed -i "/^P:$package\$/,/^\$/d" /lib/apk/db/installed
    end
    sed -i '/@local/d' /etc/apk/world
	/sbin/apk $argv
end

if status is-interactive
    # Commands to run in interactive sessions can go here
end
