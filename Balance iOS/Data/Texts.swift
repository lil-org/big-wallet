import Foundation

enum Texts {
    
    enum Shared {
        
        static var cancel: String { NSLocalizedString("shared cancel", comment: "") }
        static var see_all: String { NSLocalizedString("shared see all", comment: "") }
    }
    
    enum App {
        
        static var name_short: String { "Balance" }
        static var name_long: String { "Balance Wallet" }
        
        enum Onboarding {
            
            static var hello_title: String { Texts.App.name_long }
            static var hello_description: String { NSLocalizedString("app onboarding hello description", comment: "") }
            static var hello_action: String { NSLocalizedString("app onboarding hello action", comment: "") }
            static var hello_footer: String { NSLocalizedString("app onboarding hello footer", comment: "") }
            
            static var features_title: String { NSLocalizedString("app onboarding features title", comment: "") }
            static var features_description: String { NSLocalizedString("app onboarding features description", comment: "") }
            static var features_action: String { NSLocalizedString("app onboarding features action", comment: "") }

            static var features_1_title: String { NSLocalizedString("app onboarding features 1 title", comment: "") }
            static var features_1_description: String { NSLocalizedString("app onboarding features 1 description", comment: "") }
            static var features_2_title: String { NSLocalizedString("app onboarding features 2 title", comment: "") }
            static var features_2_description: String { NSLocalizedString("app onboarding features 2 description", comment: "") }
            static var features_3_title: String { NSLocalizedString("app onboarding features 3 title", comment: "") }
            static var features_3_description: String { NSLocalizedString("app onboarding features 3 description", comment: "") }
            static var features_4_title: String { NSLocalizedString("app onboarding features 4 title", comment: "") }
            static var features_4_description: String { NSLocalizedString("app onboarding features 4 description", comment: "") }
            
        }
    }
    
    enum Wallet {
        
        static var wallets: String { NSLocalizedString("wallet wallets", comment: "") }
        static var operation_not_supported: String { NSLocalizedString("wallet operation not supported", comment: "Balance does not support that. We must fix this.") }
        static var operation_faild: String { NSLocalizedString("wallet operation faild", comment: "Something failed. We must fix this.") }
        
        static var empty_title: String { NSLocalizedString("wallet empty title", comment: "No wallets") }
        static var empty_description: String { NSLocalizedString("wallet empty description", comment: "Create or Import a Wallet") }
        static var open_all_wallets: String { NSLocalizedString("wallet open all wallets", comment: "") } //Hide this when no wallets
        
        static var add_wallet_action: String { NSLocalizedString("wallet add wallet action", comment: "Create or Import a Wallet") }
        static var add_wallet_footer: String { NSLocalizedString("wallet add wallet footer", comment: "You can import your secret recover phrase or create a fresh new wallet.") }
        
        static var no_name: String { NSLocalizedString("wallet no name", comment: "New Wallet") }
        static var change_name: String { NSLocalizedString("wallet change name", comment: "Rename") }
        static var address: String { NSLocalizedString("wallet address", comment: "Wallet Ethereum Address") }
        static var address_footer: String { NSLocalizedString("wallet footer", comment: "All Ethereum addresses begin with 0x and are followed by 40 characters. This is how people can send assets to you that live inside the Ethereum ecosystem.") }
        static var address_copied: String { NSLocalizedString("wallet address copied", comment: "Address Copied") }
        
        static var balances_header: String { NSLocalizedString("wallet balances header", comment: "ETH Balances") }
        static var balances_subheader: String { NSLocalizedString("wallet balances subheader", comment: "You can see your ETH balance on all Ethereum Layer 2 Networks and test networks.") }
        static var balances_footer: String { NSLocalizedString("wallet balances footer", comment: "Wallets with no ETH are hidden.") } //Turn on by default
        
        static var show_empty_balances: String { NSLocalizedString("wallet balances show empty", comment: "Show Wallets with no ETH") }
        
        static var access_header: String { NSLocalizedString("wallet access header", comment: "SECRET RECOVERY PHRASE") }
        static var access_footer: String { NSLocalizedString("wallet access footer", comment: "These 12 words that can recover your funds in any wallet. They are also known as Seed Phrases or Mnemonic Phrase. You can learn more about how these work here: https://support.mycrypto.com/general-knowledge/cryptography/how-do-mnemonic-phrases-work/") }
        static var show_phrase: String { NSLocalizedString("wallet show phrase", comment: "Reveal Secret Recovery Phrase") }
        
        static var delete_header: String { NSLocalizedString("wallet delete header", comment: "DELETE WALLET - CANNOT UNDO") }
        static var delete_footer: String { NSLocalizedString("wallet delete footer", comment: "Delete Wallet Forever") }
        static var delete_action: String { NSLocalizedString("wallet delete action", comment: "If you have backed up your Secret Recovery Phrase, you can import it again. If you have not backed it up, it will be lost forever.") }
        
        static var delete_confirm_title: String { NSLocalizedString("wallet delete confirm title", comment: "Are you sure you want to delete this forever?") }
        static var delete_confirm_description: String { NSLocalizedString("wallet delete confirm description", comment: "There is no way for us to recover this for you.") }
        static var delete_confirm_action: String { NSLocalizedString("wallet delete confirm action", comment: "Yes, delete my wallet.") }
        static var delete_confirm_action_completed: String { NSLocalizedString("wallet delete confirm action completed", comment: "Wallet Deleted") }
        
        static var new_name_title: String { NSLocalizedString("wallet new name title", comment: "") }
        static var new_name_description: String { NSLocalizedString("wallet new name description", comment: "") }
        static var new_name_save: String { NSLocalizedString("wallet new name save", comment: "") }
        static var new_name_saved: String { NSLocalizedString("wallet new name saved", comment: "") }
        
        enum Operation {
            
            static var choose_wallet: String { NSLocalizedString("wallet operation choose wallet", comment: "Choose Which Wallet") }
            static var choose_network_header: String { NSLocalizedString("wallet operation choose network header", comment: "ETHEREUM-BASED NETWORKS") }
            static var choose_network_footer: String { NSLocalizedString("wallet operation choose network footer", comment: "Choose which Ethereum network you want to connect to with your wallet. ") }
            
            static var prod_networks_header: String { NSLocalizedString("wallet operation prod networks header", comment: "Live Ethereum Layer 2 networks & Sidechains") }
            static var prod_networks_footer: String { NSLocalizedString("wallet operation prod networks footer", comment: "If you want to learn more about Layer 2 Ethereum networks, go here: https://ethereum.org/en/developers/docs/scaling/layer-2-rollups/") }
            static var test_networks_header: String { NSLocalizedString("wallet operation test networks header", comment: "ETHEREUM TEST NETWORKS") }
            static var test_networks_footer: String { NSLocalizedString("wallet operation test networks footer", comment: "Test networks are used by developers who are improving their dapps for mobile web browsers like Safari. If you are a dapp developer, please join oue Discord at: https://discord.gg/balance-wallet") }
            
            static var available_wallets_header: String { NSLocalizedString("wallet operation available wallets header", comment: "YOUR WALLETS") }
            static var available_wallets_footer: String { NSLocalizedString("wallet operation available wallets footer", comment: "Which wallet do you want to use to connect to this dapp?") }
            
            static var approve_transaction: String { NSLocalizedString("wallet operation approve transaction", comment: "Approve Your Transaction") }
            static var approve_transaction_website: String { NSLocalizedString("wallet operation approve transaction website", comment: "Dapp Website") }
            static var approve_transaction_value: String { NSLocalizedString("wallet operation approve transaction value", comment: "Amount") }
            static var approve_transaction_gas: String { NSLocalizedString("wallet operation approve transaction gas", comment: "Gas") }
            static var approve_transaction_fee: String { NSLocalizedString("wallet operation approve transaction fee", comment: "Fee") }
            static var approve_transaction_address_description: String { NSLocalizedString("wallet operation approve transaction address description", comment: "This is the wallet that will be used.") }
            static var approve_transaction_details_header: String { NSLocalizedString("wallet operation approve transaction details header", comment: "Wallet Address") }
            static var approve_transaction_details_footer: String { NSLocalizedString("wallet operation approve transaction details footer", comment: "This transaction will be broadcast to the Ethereum network you chose.") }
            
            static var approve_operation: String { NSLocalizedString("wallet operation approve operation", comment: "Approve Transaction") }
            static var type: String { NSLocalizedString("wallet operation approve operation type", comment: "Cancel") }
        }
        
        enum SafariExtension {
            
            static var propose_title: String { NSLocalizedString("wallet safari extension propose title", comment: "") }
            static var propose_description: String { NSLocalizedString("wallet safari extension propose description", comment: "") }
            static var propose_header: String { NSLocalizedString("wallet safari extension propose header", comment: "") }
            static var propose_footer: String { NSLocalizedString("wallet safari extension propose footer", comment: "") }
            
            enum Steps {
                
                static var open: String { NSLocalizedString("wallet safari extension steps open", comment: "") }
                
                static var title: String { NSLocalizedString("wallet safari extension steps title", comment: "") }
                static var description: String { NSLocalizedString("wallet safari extension steps description", comment: "") }
                static var footer: String { NSLocalizedString("wallet safari extension steps footer", comment: "") }
                static var action: String { NSLocalizedString("wallet safari extension steps action", comment: "") }
            }
        }
        
        enum Import {
            
            static var title: String { NSLocalizedString("wallet import title", comment: "Import or Create Wallet") }
            static var description: String { NSLocalizedString("wallet import description", comment: "You can import an existing wallet or create a new one.") }
            
            static var action_new_title: String { NSLocalizedString("wallet import action new title", comment: "Create A Wallet") }
            static var action_new_description: String { NSLocalizedString("wallet import action new description", comment: "Create a new Ethereum wallet. You will need to add funds to it from an exchange to use it.") }
            static var action_add_exising_title: String { NSLocalizedString("wallet import action add exising title", comment: "Import A Wallet") }
            static var action_add_exising_description: String { NSLocalizedString("wallet import action add exising description", comment: "If you have a Secret Recovery Phrase from any other wallet, you can paste it into this app to access those funds.") }
            
        }
        
        enum Phrase {
            
            static var title: String { NSLocalizedString("wallet phrase title", comment: "Secret Recovery Phrase") }
            static var footer: String { NSLocalizedString("wallet phrase footer", comment: "Save or Copy Phrase") }
            static var action: String { NSLocalizedString("wallet phrase action", comment: "You should back this up somewhere safe.") }
            
            enum Actions {
                
                static var title: String { NSLocalizedString("wallet phrase actions title", comment: "Copy Phrase") }
                static var description: String { NSLocalizedString("wallet phrase actions description", comment: "We recommend pasting this phrase into a secure application like 1Password. You can do this later.") }
                static var choose: String { NSLocalizedString("wallet phrase actions choose", comment: "Choose this option") }
                static var cancel: String { NSLocalizedString("wallet phrase actions cancel", comment: "Go back to the wallet") }
                
                static var action_copy_title: String { NSLocalizedString("wallet phrase actions action copy title", comment: "Copy to Clipboard") }
                static var action_copy_description: String { NSLocalizedString("wallet phrase actions action copy description", comment: "You can copy the Secret Recovery Phrase to your clipboard.") }
                static var action_copy_completed: String { NSLocalizedString("wallet phrase actions action copy completed", comment: "Copied") }
                
                static var action_share_title: String { NSLocalizedString("wallet phrase actions action share title", comment: "Share") }
                static var action_share_description: String { NSLocalizedString("wallet phrase actions action share description", comment: "Share to an app like Notes or Messages. Not recommended!") }
            }
        }
        
        enum Destroy {
            
            static var action: String { NSLocalizedString("wallet destroy action", comment: "Delete This Wallet") }
            static var completed: String { NSLocalizedString("wallet destroy completed", comment: "Wallet Deleted") }
            static var confirm_title: String { NSLocalizedString("wallet destroy confirm title", comment: "Deleted") }
            static var confirm_description: String { NSLocalizedString("wallet destroy confirm description", comment: "") }
        }
    }
    
    enum Settings {
        
        static var title: String { NSLocalizedString("settings title", comment: "Settings") }
        
        static var notification_header: String { NSLocalizedString("settings notification header", comment: "Notifications") }
        static var notification_title: String { NSLocalizedString("settings notification title", comment: "Toggle") }
        static var notification_footer: String { NSLocalizedString("settings notification description", comment: "Balance notifies you when you are on a dapp and after you submit a transaction.") }
        
        static var app_header: String { NSLocalizedString("settings app header", comment: "App Settings") }
        static var app_footer: String { NSLocalizedString("settings app footer", comment: "If you need support, go to balance.io") }
        
        static var appearance_title: String { NSLocalizedString("settings appearance title", comment: "Light & Dark Mode") }
        static var appearance_footer: String { NSLocalizedString("settings appearance footer", comment: "You can let the app adapt automatically to your iOS settings or choose a mode.") }
        static var appearance_automatic: String { NSLocalizedString("settings appearance automatic", comment: "") }
        
        static var appearance_force_header: String { NSLocalizedString("settings appearance force header", comment: "CHOOSE A MODE") }
        static var appearance_force_footer: String { NSLocalizedString("settings appearance force footer", comment: "This will override the default iOS settings.") }
        static var appearance_force_always_light: String { NSLocalizedString("settings appearance force always light", comment: "Light") }
        static var appearance_force_always_dark: String { NSLocalizedString("settings appearance force always dark", comment: "Dark") }
        
        static var language_title: String { NSLocalizedString("settings language title", comment: "LANGUAGE") }
        static var language_footer: String { NSLocalizedString("settings language footer", comment: "If you want to help us add another language to the app, please join the Balance Discord. Go to balance.io") }
        
        static var about_title: String { NSLocalizedString("settings about title", comment: "About") }

        static var about_website: String { NSLocalizedString("settings about title", comment: "Website: balance.io") }
        static var about_twitter: String { NSLocalizedString("settings about twitter", comment: "Twitter: @balance_io") }
        static var about_discord: String { NSLocalizedString("settings about discord", comment: "Discord: discord.gg/balance-wallet") }
        
        static var about_footer: String { NSLocalizedString("settings about footer", comment: "We are a global community of engineers, designers & operators trying to build the best open source Ethereum wallet possible.") }
    }
}
