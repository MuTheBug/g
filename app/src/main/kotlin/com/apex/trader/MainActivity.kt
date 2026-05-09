package com.apex.trader

import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.material3.Surface
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.fragment.app.FragmentActivity
import androidx.hilt.navigation.compose.hiltViewModel
import com.apex.trader.presentation.component.BiometricGate
import com.apex.trader.presentation.navigation.ApexNavHost
import com.apex.trader.presentation.navigation.RootViewModel
import com.apex.trader.presentation.theme.ApexTheme
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class MainActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            ApexTheme {
                Surface(modifier = Modifier) {
                    val rootVm: RootViewModel = hiltViewModel()
                    val biometricEnabled by rootVm.biometricLockEnabled.collectAsState()
                    BiometricGate(enabled = biometricEnabled) {
                        ApexNavHost()
                    }
                }
            }
        }
    }
}
