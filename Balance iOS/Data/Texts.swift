import Foundation

enum Texts {
    
    enum Shared {
        
        static var cancel: String { "cancel" }
        static var see_all: String { "see all" }
    }
    
    enum App {
        
        static var name_short: String { "Balance" }
        static var name_long: String { "Balance ETH Wallet" }
        
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
        static var operation_not_supported: String { NSLocalizedString("wallet operation not supported", comment: "") }
        static var operation_faild: String { NSLocalizedString("wallet operation faild", comment: "") }
        
        static var empty_title: String { NSLocalizedString("wallet empty title", comment: "") }
        static var empty_description: String { NSLocalizedString("wallet empty description", comment: "") }
        static var open_all_wallets: String { NSLocalizedString("wallet open all wallets", comment: "") }
        
        static var add_wallet_action: String { NSLocalizedString("wallet add wallet action", comment: "") }
        static var add_wallet_footer: String { NSLocalizedString("wallet add wallet footer", comment: "") }
        
        static var no_name: String { "wallet no name" }
        static var change_name: String { "wallet change name" }
        static var address: String { "wallet address" }
        static var address_copied: String { "wallet address copied" }
        
        static var balances_header: String { "wallet balances header" }
        static var balances_footer: String { "wallet balances footer" }
        
        static var show_empty_balances: String { "wallet balances show empty" }
        
        static var access_header: String { "wallet access header" }
        static var access_footer: String { "wallet access footer" }
        static var show_phrase: String { "wallet show phrase" }
        
        static var delete_header: String { "wallet delete header" }
        static var delete_footer: String { "wallet delete footer" }
        static var delete_action: String { "wallet delete action" }
        
        static var delete_confirm_title: String { "wallet delete confirm title" }
        static var delete_confirm_description: String { "wallet delete confirm description" }
        static var delete_confirm_action: String { "wallet delete confirm action" }
        static var delete_confirm_action_completed: String { "wallet delete confirm action completed" }
        
        static var new_name_title: String { "wallet new name title" }
        static var new_name_description: String { "wallet new name description" }
        static var new_name_save: String { "wallet new name save" }
        static var new_name_saved: String { "wallet new name saved" }
        
        enum Operation {
            
            static var choose_wallet: String { NSLocalizedString("wallet operation choose wallet", comment: "") }
            static var choose_network_header: String { NSLocalizedString("wallet operation choose network header", comment: "") }
            static var choose_network_footer: String { NSLocalizedString("wallet operation choose network footer", comment: "") }
            
            static var prod_networks_header: String { NSLocalizedString("wallet operation prod networks header", comment: "") }
            static var prod_networks_footer: String { NSLocalizedString("wallet operation prod networks footer", comment: "") }
            static var test_networks_header: String { NSLocalizedString("wallet operation test networks header", comment: "") }
            static var test_networks_footer: String { NSLocalizedString("wallet operation test networks header", comment: "") }
            
            static var available_wallets_header: String { NSLocalizedString("wallet operation available wallets header", comment: "") }
            static var available_wallets_footer: String { NSLocalizedString("wallet operation available wallets footer", comment: "") }
            
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
        
        static var title: String { NSLocalizedString("settings title", comment: "") }
        
        static var notification_title: String { NSLocalizedString("settings notification title", comment: "") }
        static var notification_header: String { NSLocalizedString("settings notification header", comment: "") }
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
        static var about_footer: String { NSLocalizedString("settings about footer", comment: "") }
    }
}
