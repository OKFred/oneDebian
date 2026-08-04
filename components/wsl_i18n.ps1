# ==============================================================================
# components/wsl_i18n.ps1
# Description: WSL 管理工具箱多语言 (i18n) 资源与字典
# ==============================================================================

# 默认根据当前 Windows 系统语言自动初始化
if (-not $script:CurrentLang) {
    $uiLang = [System.Globalization.CultureInfo]::CurrentUICulture.Name
    $script:CurrentLang = if ($uiLang -like 'zh*') { 'zh-CN' } else { 'en-US' }
}

# 简易双语字典
$script:I18nDict = @{
    # 主菜单
    'Menu_Title'             = @{ 'zh-CN' = 'oneDebian WSL 管理工具箱 (Windows PS)'; 'en-US' = 'oneDebian WSL Management Toolbox (Windows PS)' }
    'Menu_Install'           = @{ 'zh-CN' = '01. Install   - 安装 Debian WSL 发行版'; 'en-US' = '01. Install   - Install Debian WSL Distribution' }
    'Menu_Update'            = @{ 'zh-CN' = '02. Update    - 更新 系统软件包与 WSL 核心'; 'en-US' = '02. Update    - Update System Packages & WSL Core' }
    'Menu_Backup'            = @{ 'zh-CN' = '03. Backup    - 备份 (导出) WSL 发行版'; 'en-US' = '03. Backup    - Export/Backup WSL Distribution' }
    'Menu_Restore'           = @{ 'zh-CN' = '04. Restore   - 还原 (导入) WSL 发行版'; 'en-US' = '04. Restore   - Import/Restore WSL Distribution' }
    'Menu_Uninstall'         = @{ 'zh-CN' = '05. Uninstall - 卸载 (注销) WSL 发行版'; 'en-US' = '05. Uninstall - Unregister/Uninstall WSL Distribution' }
    'Menu_Config'            = @{ 'zh-CN' = '06. Config    - WSL 配置向导 (.wslconfig & wsl.conf)'; 'en-US' = '06. Config    - WSL Config Helper (.wslconfig & wsl.conf)' }
    'Menu_Lang'              = @{ 'zh-CN' = 'L.  Language  - 切换界面语言 (Language)'; 'en-US' = 'L.  Language  - Switch Display Language' }
    'Menu_About'             = @{ 'zh-CN' = '99. About     - 关于工具箱'; 'en-US' = '99. About     - About Toolbox' }
    'Menu_Exit'              = @{ 'zh-CN' = '00. Exit      - 退出程序'; 'en-US' = '00. Exit      - Exit Toolbox' }
    'Prompt_Select'          = @{ 'zh-CN' = '请输入功能编号 [01-06, L, 99, 00]'; 'en-US' = 'Please enter option number [01-06, L, 99, 00]' }
    'Err_InvalidChoice'      = @{ 'zh-CN' = '[!] 输入未匹配到有效选项，请正确输入！'; 'en-US' = '[!] Unmatched option, please enter a valid choice!' }
    'Msg_Pause'              = @{ 'zh-CN' = 'Press any key to return to menu... (按任意键返回主菜单)'; 'en-US' = 'Press any key to return to menu...' }
    'Msg_Bye'                = @{ 'zh-CN' = '已退出工具箱。 Bye!'; 'en-US' = 'Exited Toolbox. Bye!' }

    # 公共交互
    'Cancel_Operation'       = @{ 'zh-CN' = '操作已取消。'; 'en-US' = 'Operation cancelled.' }
    'Select_Distro_Title'    = @{ 'zh-CN' = '请选择 WSL 发行版'; 'en-US' = 'Please select a WSL Distribution' }
    'No_Distro_Found'        = @{ 'zh-CN' = '未检测到任何已安装的 WSL 发行版。'; 'en-US' = 'No installed WSL distribution detected.' }
    'Select_Index_Prompt'    = @{ 'zh-CN' = '请输入序号'; 'en-US' = 'Please enter number' }

    # 安装
    'Install_Title'          = @{ 'zh-CN' = '1. 安装 Debian WSL 发行版'; 'en-US' = '1. Install Debian WSL Distribution' }
    'Install_Version_Prompt' = @{ 'zh-CN' = '选择 Debian 版本 (支持 12 / 13，默认 13)'; 'en-US' = 'Select Debian Version (12 / 13 supported, Default: 13)' }
    'Install_Dir_Prompt'     = @{ 'zh-CN' = '输入安装根目录'; 'en-US' = 'Enter Install Root Directory' }
    'Install_Confirm_Title'  = @{ 'zh-CN' = '[!] 安装参数确认:'; 'en-US' = '[!] Installation Parameters Confirmation:' }
    'Install_Confirm_Prompt' = @{ 'zh-CN' = '确认开始下载并安装'; 'en-US' = 'Confirm start downloading and installing' }

    # 卸载
    'Uninstall_Title'        = @{ 'zh-CN' = '5. 卸载 (注销) WSL 发行版'; 'en-US' = '5. Unregister/Uninstall WSL Distribution' }
    'Uninstall_Select_Title' = @{ 'zh-CN' = '=== 选择要卸载注销的 WSL 发行版 ==='; 'en-US' = '=== Select WSL Distributions to Uninstall ===' }
    'Uninstall_Warn_Step1'   = @{ 'zh-CN' = '[!] ⚠️ 警告: 准备注销卸载以下 WSL 发行版:'; 'en-US' = '[!] ⚠️ Warning: Preparing to unregister the following WSL distros:' }
    'Uninstall_Confirm_Step1'= @{ 'zh-CN' = '[1/2 第一次确认] 确认要继续吗？(输入 Y 确认继续)'; 'en-US' = '[1/2 First Confirmation] Are you sure to continue? (Enter Y to proceed)' }
    'Uninstall_Confirm_Step2'= @{ 'zh-CN' = '[2/2 第二次确认] 请手动输入大写 ''DELETE'' 以最终执行'; 'en-US' = '[2/2 Final Confirmation] Please type uppercase ''DELETE'' to execute' }

    # 配置
    'Config_Title'           = @{ 'zh-CN' = '6. WSL 引导式配置向导 (Config)'; 'en-US' = '6. WSL Guided Config Helper (Config)' }
    'Config_Opt_Global'      = @{ 'zh-CN' = '[1] 全局配置文件 (.wslconfig - 影响所有 WSL 实例)'; 'en-US' = '[1] Global Configuration (.wslconfig - affects all WSL instances)' }
    'Config_Opt_Distro'      = @{ 'zh-CN' = '[2] 单个分发配置 (/etc/wsl.conf - 影响指定 Linux 实例)'; 'en-US' = '[2] Per-distro Configuration (/etc/wsl.conf - affects specific Linux instance)' }
    'Config_Hint_Format'     = @{ 'zh-CN' = '[按回车: 应用默认值 (%s) | 输入 ''--'': 不填/跳过]'; 'en-US' = '[Press Enter: Use Default (%s) | Type ''--'': Skip/Omit]' }
}

function Get-I18nStr {
    param(
        [string]$Key,
        [object[]]$Args = @()
    )

    $text = $Key
    if ($script:I18nDict.ContainsKey($Key)) {
        $entry = $script:I18nDict[$Key]
        if ($entry.ContainsKey($script:CurrentLang)) {
            $text = $entry[$script:CurrentLang]
        } else {
            $text = $entry['zh-CN']
        }
    }

    if ($Args.Count -gt 0) {
        return [string]::Format($text, $Args)
    }
    return $text
}

function Toggle-Language {
    if ($script:CurrentLang -eq 'zh-CN') {
        $script:CurrentLang = 'en-US'
        Write-Host "`n[✓] Language switched to English!" -ForegroundColor Green
    } else {
        $script:CurrentLang = 'zh-CN'
        Write-Host "`n[✓] 界面语言已切换为 简体中文！" -ForegroundColor Green
    }
    Start-Sleep -Seconds 1
}
