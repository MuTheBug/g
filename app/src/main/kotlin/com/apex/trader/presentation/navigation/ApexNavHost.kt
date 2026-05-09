package com.apex.trader.presentation.navigation

import androidx.compose.runtime.Composable
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.apex.trader.presentation.screen.about.AboutScreen
import com.apex.trader.presentation.screen.positions.PositionsScreen
import com.apex.trader.presentation.screen.scanner.ScannerScreen
import com.apex.trader.presentation.screen.settings.SettingsScreen
import com.apex.trader.presentation.screen.setup.SetupScreen
import com.apex.trader.presentation.screen.signal.SignalDetailScreen
import com.apex.trader.presentation.screen.trade.TradeScreen
import com.apex.trader.data.local.CredentialsStore

object Routes {
    const val SETUP = "setup"
    const val SCANNER = "scanner"
    const val SIGNAL_DETAIL = "signal/{symbol}"
    const val TRADE = "trade/{symbol}"
    const val POSITIONS = "positions"
    const val SETTINGS = "settings"
    const val ABOUT = "about"

    fun signalDetail(symbol: String) = "signal/$symbol"
    fun trade(symbol: String) = "trade/$symbol"
}

@Composable
fun ApexNavHost() {
    val navController = rememberNavController()
    // Decide start destination based on whether credentials exist.
    val store: CredentialsStore = hiltViewModel<RootViewModel>().credentialsStore
    val hasCreds = store.snapshot() != null
    val start = if (hasCreds) Routes.SCANNER else Routes.SETUP

    NavHost(navController = navController, startDestination = start) {
        composable(Routes.SETUP) {
            SetupScreen(onSaved = {
                navController.navigate(Routes.SCANNER) {
                    popUpTo(Routes.SETUP) { inclusive = true }
                }
            })
        }
        composable(Routes.SCANNER) {
            ScannerScreen(
                onSignalClick = { symbol -> navController.navigate(Routes.signalDetail(symbol)) },
                onPositionsClick = { navController.navigate(Routes.POSITIONS) },
                onSettingsClick = { navController.navigate(Routes.SETTINGS) }
            )
        }
        composable(
            route = Routes.SIGNAL_DETAIL,
            arguments = listOf(navArgument("symbol") { type = NavType.StringType })
        ) { backStack ->
            val symbol = backStack.arguments?.getString("symbol").orEmpty()
            SignalDetailScreen(
                symbol = symbol,
                onTradeClick = { navController.navigate(Routes.trade(symbol)) },
                onBack = { navController.popBackStack() }
            )
        }
        composable(
            route = Routes.TRADE,
            arguments = listOf(navArgument("symbol") { type = NavType.StringType })
        ) { backStack ->
            val symbol = backStack.arguments?.getString("symbol").orEmpty()
            TradeScreen(
                symbol = symbol,
                onDone = {
                    navController.popBackStack(Routes.SCANNER, inclusive = false)
                },
                onBack = { navController.popBackStack() }
            )
        }
        composable(Routes.POSITIONS) {
            PositionsScreen(onBack = { navController.popBackStack() })
        }
        composable(Routes.SETTINGS) {
            SettingsScreen(
                onBack = { navController.popBackStack() },
                onAboutClick = { navController.navigate(Routes.ABOUT) }
            )
        }
        composable(Routes.ABOUT) {
            AboutScreen(onBack = { navController.popBackStack() })
        }
    }
}
