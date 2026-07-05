import Foundation
import Supabase

/// Single shared Supabase client. Both the app and the share extension build
/// their client from the same config and shared keychain storage, so signing
/// in once in the app authenticates shares from the extension too.
enum SupabaseClientProvider {
    static var currentUserId: UUID? {
        shared.auth.currentSession?.user.id
    }

    static let shared: SupabaseClient = SupabaseClient(
        supabaseURL: SupabaseConfig.url,
        supabaseKey: SupabaseConfig.anonKey,
        options: SupabaseClientOptions(
            auth: SupabaseClientOptions.AuthOptions(
                storage: SharedKeychainStorage()
            )
        )
    )
}
