install_tools() {
    if ! command -v jq &>/dev/null; then
        sudo apt-get update
        sudo apt-get install -y jq
    else
        echo "[${FUNCNAME[0]}] jq already installed"
    fi
}

install_az_cli() {
    if ! command -v az &>/dev/null; then
        curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    else
        echo "[${FUNCNAME[0]}] Azure CLI already installed"
    fi
}

install_powershell() {
    if ! command -v pwsh &>/dev/null; then
        # Update the list of packages
        sudo apt-get update
        # Install pre-requisite packages.
        sudo apt-get install -y wget apt-transport-https software-properties-common
        # Download the Microsoft repository GPG keys
        wget -q "https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb"
        # Register the Microsoft repository GPG keys
        sudo dpkg -i packages-microsoft-prod.deb
        # Delete the the Microsoft repository GPG keys file
        rm packages-microsoft-prod.deb
        # Update the list of packages after we added packages.microsoft.com
        sudo apt-get update
        # Install PowerShell
        sudo apt-get install -y powershell
    else
        echo "[${FUNCNAME[0]}] Powershell already installed"
    fi
}

install_azureadmodule() {
    echo "[${FUNCNAME[0]}] Installing Microsoft.Graph module"
    pwsh -Command "If(-not(Get-InstalledModule Microsoft.Graph -ErrorAction silentlycontinue)){Install-Module Microsoft.Graph -Confirm:\$False -Force}"
}

install_tools
install_az_cli
install_powershell
install_azureadmodule
