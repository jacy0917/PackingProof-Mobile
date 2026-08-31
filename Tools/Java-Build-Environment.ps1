function Enter-JavaBuildEnvironment {
    param([Parameter(Mandatory)][string]$RepositoryRoot)

    $state = [ordered]@{
        TempExists = Test-Path Env:TEMP
        Temp = $env:TEMP
        TmpExists = Test-Path Env:TMP
        Tmp = $env:TMP
    }
    $temporaryDirectory = Join-Path $RepositoryRoot '.dart_tool/java-build-temp'
    New-Item -ItemType Directory -Force -Path $temporaryDirectory | Out-Null
    $env:TEMP = $temporaryDirectory
    $env:TMP = $temporaryDirectory
    return $state
}

function Exit-JavaBuildEnvironment {
    param([Parameter(Mandatory)]$State)

    if ($State.TempExists) {
        $env:TEMP = $State.Temp
    }
    else {
        Remove-Item Env:TEMP -ErrorAction SilentlyContinue
    }
    if ($State.TmpExists) {
        $env:TMP = $State.Tmp
    }
    else {
        Remove-Item Env:TMP -ErrorAction SilentlyContinue
    }
}
