# PSScriptAnalyzer rules enforced in CI.
# A focused set: field safety, secrets and Windows PowerShell 5.1 compatibility.
# Style rules (Write-Host, aliases ...) are intentionally not enforced.
@{
    IncludeRules = @(
        'PSUseBOMForUnicodeEncodedFile',
        'PSUseCompatibleSyntax',
        'PSAvoidUsingInvokeExpression',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSAvoidUsingUsernameAndPasswordParams',
        'PSAvoidUsingComputerNameHardcoded',
        'PSAvoidUsingEmptyCatchBlock'
    )

    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
