Describe 'Tag-CleanupCandidates' {
    It 'should reject non-existent CSV path' {
        { & "$PSScriptRoot/../cleanup/Tag-CleanupCandidates.ps1" -InputCsv '/nonexistent/path.csv' -WhatIf } |
            Should -Throw
    }

    It 'should reject GracePeriodDays less than 1' {
        { & "$PSScriptRoot/../cleanup/Tag-CleanupCandidates.ps1" -GracePeriodDays 0 -WhatIf } |
            Should -Throw
    }

    It 'should reject GracePeriodDays over 365' {
        { & "$PSScriptRoot/../cleanup/Tag-CleanupCandidates.ps1" -GracePeriodDays 400 -WhatIf } |
            Should -Throw
    }
}
