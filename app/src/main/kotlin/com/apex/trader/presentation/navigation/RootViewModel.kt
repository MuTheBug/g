package com.apex.trader.presentation.navigation

import androidx.lifecycle.ViewModel
import com.apex.trader.data.local.CredentialsStore
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject

@HiltViewModel
class RootViewModel @Inject constructor(
    val credentialsStore: CredentialsStore
) : ViewModel()
