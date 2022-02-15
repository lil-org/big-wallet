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
    
    enum NFT {
        
        static var title: String { NSLocalizedString("nft title", comment: "") }
    }
    
    enum Wallet {
        
        static var wallets: String { NSLocalizedString("wallet wallets", comment: "") }
        static var operation_not_supported: String { NSLocalizedString("wallet operation not supported", comment: "") }
        static var operation_faild: String { NSLocalizedString("wallet operation faild", comment: "") }
        
        static var empty_title: String { NSLocalizedString("wallet empty title", comment: "") }
        static var empty_description: String { NSLocalizedString("wallet empty description", comment: "") }
        static var open_all_wallets: String { NSLocalizedString("wallet open all wallets", comment: "") } //Hide this when no wallets
        
        static var add_wallet_action: String { NSLocalizedString("wallet add wallet action", comment: "") }
        static var add_wallet_footer: String { NSLocalizedString("wallet add wallet footer", comment: "") }
        
        static var no_name: String { NSLocalizedString("wallet no name", comment: "") }
        static var change_name: String { NSLocalizedString("wallet change name", comment: "") }
        static var address: String { NSLocalizedString("wallet address", comment: "") }
        static var address_footer: String { NSLocalizedString("wallet footer", comment: "") }
        static var address_copied: String { NSLocalizedString("wallet address copied", comment: "") }
        
        static var balances_header: String { NSLocalizedString("wallet balances header", comment: "") }
        static var balances_subheader: String { NSLocalizedString("wallet balances subheader", comment: "") }
        static var balances_footer: String { NSLocalizedString("wallet balances footer", comment: "") } //Turn on by default
        
        static var show_empty_balances: String { NSLocalizedString("wallet balances show empty", comment: "") }
        
        static var access_header: String { NSLocalizedString("wallet access header", comment: "") }
        static var access_footer: String { NSLocalizedString("wallet access footer", comment: "") }
        static var show_phrase: String { NSLocalizedString("wallet show phrase", comment: "") }
        
        static var delete_header: String { NSLocalizedString("wallet delete header", comment: "") }
        static var delete_footer: String { NSLocalizedString("wallet delete footer", comment: "") }
        static var delete_action: String { NSLocalizedString("wallet delete action", comment: "") }
        
        static var delete_confirm_title: String { NSLocalizedString("wallet delete confirm title", comment: "") }
        static var delete_confirm_description: String { NSLocalizedString("wallet delete confirm description", comment: "") }
        static var delete_confirm_action: String { NSLocalizedString("wallet delete confirm action", comment: "") }
        static var delete_confirm_action_completed: String { NSLocalizedString("wallet delete confirm action completed", comment: "") }
        
        static var new_name_title: String { NSLocalizedString("wallet new name title", comment: "") }
        static var new_name_description: String { NSLocalizedString("wallet new name description", comment: "") }
        static var new_name_save: String { NSLocalizedString("wallet new name save", comment: "") }
        static var new_name_saved: String { NSLocalizedString("wallet new name saved", comment: "") }
        
        enum Operation {
            
            static var choose_wallet: String { NSLocalizedString("wallet operation choose wallet", comment: "") }
            static var choose_network_header: String { NSLocalizedString("wallet operation choose network header", comment: "") }
            static var choose_network_footer: String { NSLocalizedString("wallet operation choose network footer", comment: "") }
            
            static var prod_networks_header: String { NSLocalizedString("wallet operation prod networks header", comment: "") }
            static var prod_networks_footer: String { NSLocalizedString("wallet operation prod networks footer", comment: "") }
            static var test_networks_header: String { NSLocalizedString("wallet operation test networks header", comment: "") }
            static var test_networks_footer: String { NSLocalizedString("wallet operation test networks footer", comment: "") }
            
            static var available_wallets_header: String { NSLocalizedString("wallet operation available wallets header", comment: "") }
            static var available_wallets_footer: String { NSLocalizedString("wallet operation available wallets footer", comment: "") }
            
            static var approve_transaction_gas_header: String { NSLocalizedString("wallet operation approve transaction gas header", comment: "") }
            
            static var approve_transaction: String { NSLocalizedString("wallet operation approve transaction", comment: "") }
            static var approve_transaction_website: String { NSLocalizedString("wallet operation approve transaction website", comment: "") }
            static var approve_transaction_value: String { NSLocalizedString("wallet operation approve transaction value", comment: "") }
            static var approve_transaction_gas: String { NSLocalizedString("wallet operation approve transaction gas", comment: "") }
            static var approve_transaction_fee: String { NSLocalizedString("wallet operation approve transaction fee", comment: "") }
            static var approve_transaction_address_description: String { NSLocalizedString("wallet operation approve transaction address description", comment: "") }
            static var approve_transaction_details_header: String { NSLocalizedString("wallet operation approve transaction details header", comment: "") }
            static var approve_transaction_details_footer: String { NSLocalizedString("wallet operation approve transaction details footer", comment: "") }
            
            static var approve_operation: String { NSLocalizedString("wallet operation approve operation", comment: "") }
            static var type: String { NSLocalizedString("wallet operation approve operation type", comment: "") }
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
            
            static var title: String { NSLocalizedString("wallet import title", comment: "") }
            static var description: String { NSLocalizedString("wallet import description", comment: "") }
            
            static var action_new_title: String { NSLocalizedString("wallet import action new title", comment: "") }
            static var action_new_description: String { NSLocalizedString("wallet import action new description", comment: "") }
            static var action_add_exising_title: String { NSLocalizedString("wallet import action add exising title", comment: "") }
            static var action_add_exising_description: String { NSLocalizedString("wallet import action add exising description", comment: "") }
            
        }
        
        enum Phrase {
            
            static var title: String { NSLocalizedString("wallet phrase title", comment: "") }
            static var footer: String { NSLocalizedString("wallet phrase footer", comment: "") }
            static var action: String { NSLocalizedString("wallet phrase action", comment: "") }
            
            enum Actions {
                
                static var title: String { NSLocalizedString("wallet phrase actions title", comment: "") }
                static var description: String { NSLocalizedString("wallet phrase actions description", comment: "") }
                static var choose: String { NSLocalizedString("wallet phrase actions choose", comment: "") }
                static var cancel: String { NSLocalizedString("wallet phrase actions cancel", comment: "") }
                
                static var action_copy_title: String { NSLocalizedString("wallet phrase actions action copy title", comment: "") }
                static var action_copy_description: String { NSLocalizedString("wallet phrase actions action copy description", comment: "") }
                static var action_copy_completed: String { NSLocalizedString("wallet phrase actions action copy completed", comment: "") }
                
                static var action_share_title: String { NSLocalizedString("wallet phrase actions action share title", comment: "") }
                static var action_share_description: String { NSLocalizedString("wallet phrase actions action share description", comment: "") }
            }
        }
        
        enum Destroy {
            
            static var action: String { NSLocalizedString("wallet destroy action", comment: "") }
            static var completed: String { NSLocalizedString("wallet destroy completed", comment: "") }
            static var confirm_title: String { NSLocalizedString("wallet destroy confirm title", comment: "") }
            static var confirm_description: String { NSLocalizedString("wallet destroy confirm description", comment: "") }
        }
    }
    
    enum Settings {
        
        static var title: String { NSLocalizedString("settings title", comment: "Settings") }
        
        static var notification_header: String { NSLocalizedString("settings notification header", comment: "") }
        static var notification_title: String { NSLocalizedString("settings notification title", comment: "") }
        static var notification_footer: String { NSLocalizedString("settings notification description", comment: "") }
        
        static var app_header: String { NSLocalizedString("settings app header", comment: "") }
        static var app_footer: String { NSLocalizedString("settings app footer", comment: "") }
        
        static var appearance_title: String { NSLocalizedString("settings appearance title", comment: "") }
        static var appearance_footer: String { NSLocalizedString("settings appearance footer", comment: "") }
        static var appearance_automatic: String { NSLocalizedString("settings appearance automatic", comment: "") }
        
        static var appearance_force_header: String { NSLocalizedString("settings appearance force header", comment: "") }
        static var appearance_force_footer: String { NSLocalizedString("settings appearance force footer", comment: "") }
        static var appearance_force_always_light: String { NSLocalizedString("settings appearance force always light", comment: "") }
        static var appearance_force_always_dark: String { NSLocalizedString("settings appearance force always dark", comment: "") }
        
        static var language_title: String { NSLocalizedString("settings language title", comment: "") }
        static var language_footer: String { NSLocalizedString("settings language footer", comment: "") }
        
        static var about_title: String { NSLocalizedString("settings about title", comment: "") }
        static var intercom_title: String { NSLocalizedString("settings intercom title", comment: "") }

        static var about_website: String { NSLocalizedString("settings about website", comment: "") }
        static var about_twitter: String { NSLocalizedString("settings about twitter", comment: "") }
        static var about_discord: String { NSLocalizedString("settings about discord", comment: "") }
        
        static var wallet_style_header: String { NSLocalizedString("settings wallet style header", comment: "") }
        static var wallet_style_footer: String { NSLocalizedString("settings wallet style footer", comment: "") }
        static var wallet_style_title: String { NSLocalizedString("settings wallet style title", comment: "") }
        
        static var wallet_style_only_name: String { NSLocalizedString("settings wallet style only name", comment: "") }
        static var wallet_style_only_address: String { NSLocalizedString("settings wallet style only address", comment: "") }
        static var wallet_style_name_address: String { NSLocalizedString("settings wallet style name and address", comment: "") }
        
        static var about_footer: String { NSLocalizedString("settings about footer", comment: "") }
    }
}
