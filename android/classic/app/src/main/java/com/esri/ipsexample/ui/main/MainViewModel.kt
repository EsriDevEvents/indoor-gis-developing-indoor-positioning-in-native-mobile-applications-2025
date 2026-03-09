package com.esri.ipsexample.ui.main

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.arcgismaps.exceptions.ArcGISException
import com.arcgismaps.location.IndoorPositioningDataOrigin
import com.arcgismaps.location.IndoorPositioningDefinition
import com.arcgismaps.location.IndoorsLocationDataSource
import com.arcgismaps.location.IndoorsLocationDataSourceConfiguration
import com.arcgismaps.location.Location
import com.arcgismaps.location.LocationDataSourceStatus
import com.arcgismaps.mapping.ArcGISMap
import com.arcgismaps.mapping.PortalItem
import com.arcgismaps.portal.Portal
import com.esri.ipsexample.R
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class MainViewModel : ViewModel() {
    val portalURL = "https://viennardc.maps.arcgis.com"
    private var indoorsLocationDataSource: IndoorsLocationDataSource? = null

    private val _uiState = MutableStateFlow(UiState())
    val uiState: StateFlow<UiState> = _uiState.asStateFlow()

    private val _locationDetailsState = MutableStateFlow<LocationDetailsState?>(null)
    val locationDetailsState: StateFlow<LocationDetailsState?> = _locationDetailsState.asStateFlow()

    fun connectToPortal() {
        viewModelScope.launch {
            _uiState.update { currentUiState -> currentUiState.copy(showProgressBar = true) }

            val portal = Portal(portalURL, Portal.Connection.Authenticated)
            portal.load()
                .onSuccess {
                    val arcGisMap =
                        ArcGISMap(PortalItem(portal, "d0f8367d7531492ba303bf65613dc02e"))
                    arcGisMap.load()
                        .onSuccess {
                            _uiState.update { currentUiState -> currentUiState.copy(map = arcGisMap) }
                            // Load IPS data and start IndoorLocationDataSource
                            loadIPSDataAndStartIndoorsLocationDataSource(arcGisMap)
                        }
                        .onFailure {
                            presentError(R.string.error_map_loading)
                        }
                }
                .onFailure {
                    Log.d("MainViewModel", "Error: ${(it as? ArcGISException)?.localizedMessage}")
                    presentError(R.string.error_portal_loading)
                }
        }
    }

    private suspend fun loadIPSDataAndStartIndoorsLocationDataSource(arcGISMap: ArcGISMap) {
        val indoorPositioningDefinition = arcGISMap.indoorPositioningDefinition
        if (indoorPositioningDefinition == null) {
            presentError(R.string.error_no_ips_supported)
            return
        }

        val isBluetoothCapable = indoorPositioningDefinition.isBluetoothCapable
        val isWifiCapable = indoorPositioningDefinition.isWifiCapable

        // Required for indoorPositioningDefinition.positioningTableInfo and indoorPositioningDefinition.serviceGeodatabaseURL
        indoorPositioningDefinition.load()
            .onSuccess {
                when (val dataOrigin = indoorPositioningDefinition.dataOrigin) {
                    is IndoorPositioningDataOrigin.Geodatabase -> {
                        Log.i("MainViewModel", "dataOrigin: Offline Geodatabase")
                    }

                    is IndoorPositioningDataOrigin.PositioningTable -> {
                        val guid = dataOrigin.tableInfo?.globalId
                        Log.i(
                            "MainViewModel",
                            "dataOrigin: Classic PositioningTable, GUID:$guid, isBluetoothCapable: $isBluetoothCapable, isWifiCapable: $isWifiCapable"
                        )
                    }

                    is IndoorPositioningDataOrigin.ServiceGeodatabase -> {
                        val portalItem = PortalItem(dataOrigin.url)
                        portalItem.load().getOrNull()
                        Log.i(
                            "MainViewModel",
                            "dataOrigin: ServiceGeodatabase,  title: ${portalItem.title}, owner: ${portalItem.owner}, isBluetoothCapable: $isBluetoothCapable, isWifiCapable: $isWifiCapable"
                        )
                    }
                }

                indoorsLocationDataSource =
                    setupIndoorsLocationDataSource(indoorPositioningDefinition)

                _uiState.update { currentUiState ->
                    currentUiState.copy(
                        mapState = MapState.MAP_LOADED,
                        indoorsLocationDataSource = indoorsLocationDataSource,
                        showProgressBar = false,
                        errorString = null,
                        startStopButtonText = R.string.startILDSButton,
                        startStopButtonVisibility = true,
                    )
                }
            }
            .onFailure {
                presentError(R.string.error_load_ips_data)
            }
    }

    private fun setupIndoorsLocationDataSource(indoorPositioningDefinition: IndoorPositioningDefinition): IndoorsLocationDataSource {
        val indoorsLocationDataSource = IndoorsLocationDataSource(indoorPositioningDefinition)

        val sharedConfiguration = indoorPositioningDefinition.configuration
        val detachedConfiguration = indoorPositioningDefinition.configuration?.clone()
        val ildsConfiguration = indoorsLocationDataSource.configuration

        // Apply local configuration settings
        ildsConfiguration.areInfoMessagesEnabled = true
        ildsConfiguration.isGnssEnabled = true

        indoorsLocationDataSource.locationChanged.onEach {
            updateUI(it)
        }.launchIn(viewModelScope)

        indoorsLocationDataSource.status.drop(1).onEach { status ->
            when (status) {
                LocationDataSourceStatus.Starting -> {
                    handleILDSStatusUpdate(MapState.ILDS_STARTING)
                }

                LocationDataSourceStatus.Started -> {
                    handleILDSStatusUpdate(MapState.ILDS_STARTED)
                }

                LocationDataSourceStatus.FailedToStart -> {
                    handleILDSStatusUpdate(
                        MapState.ILDS_FAILED_TO_START,
                        R.string.error_ilds_failed_to_start
                    )
                }

                LocationDataSourceStatus.Stopped -> {
                    val error = indoorsLocationDataSource.error.value as? ArcGISException
                    Log.d("MainViewModel", "error: ${error?.localizedMessage}")
                    handleILDSStatusUpdate(
                        MapState.ILDS_STOPPED, if (error != null) {
                            R.string.error_ilds_stopped
                        } else {
                            null
                        }
                    )
                    _locationDetailsState.update { currentState -> currentState?.copy(isVisible = false) }
                }

                else -> {}
            }
        }.launchIn(viewModelScope)

        return indoorsLocationDataSource
    }

    fun startIndoorsLocationDataSource() {
        viewModelScope.launch {
            _uiState.update { currentUiState -> currentUiState.copy(startStopButtonVisibility = false) }
            indoorsLocationDataSource?.start() ?: kotlin.run {
                _uiState.value.map?.let {
                    loadIPSDataAndStartIndoorsLocationDataSource(it)
                }
            }
        }
    }

    fun stopIndoorsLocationDataSource() {
        viewModelScope.launch {
            indoorsLocationDataSource?.stop()
        }
    }

    private fun updateUI(location: Location) {
        val floor =
            location.additionalSourceProperties[Location.SourceProperties.Keys.FLOOR] as? Int
        val positionSource =
            location.additionalSourceProperties[Location.SourceProperties.Keys.POSITION_SOURCE] as? String
        val transmitterCount =
            location.additionalSourceProperties[Location.SourceProperties.Keys.TRANSMITTER_COUNT] as? Int
        val networkCount =
            location.additionalSourceProperties[Location.SourceProperties.Keys.SATELLITE_COUNT] as? Int

        _locationDetailsState.value = LocationDetailsState(
            floor = floor,
            positionSourceText = positionSource,
            horizontalAccuracyText = location.horizontalAccuracy,
            senderCount = if (positionSource == Location.SourceProperties.Values.POSITION_SOURCE_GNSS) {
                networkCount
            } else {
                transmitterCount
            }
        )
    }

    private fun handleILDSStatusUpdate(mapState: MapState, errorString: Int? = null) {
        _uiState.update { currentUiState ->
            currentUiState.copy(
                mapState = if (mapState == MapState.ILDS_FAILED_TO_START) {
                    MapState.MAP_LOADED
                } else {
                    mapState
                },
                startStopButtonText = if (mapState == MapState.ILDS_STARTED) {
                    R.string.stopILDSButton
                } else {
                    R.string.startILDSButton
                },
                startStopButtonVisibility = mapState != MapState.ILDS_STARTING,
                showProgressBar = mapState == MapState.ILDS_STARTING,
                errorString = errorString
            )
        }
    }

    private fun presentError(stringRes: Int?) {
        _uiState.update { currentUiState ->
            currentUiState.copy(
                showProgressBar = false,
                errorString = stringRes
            )
        }
    }
}

enum class MapState {
    INIT,
    MAP_LOADED,
    ILDS_STARTING,
    ILDS_STARTED,
    ILDS_FAILED_TO_START,
    ILDS_STOPPED
}

data class UiState(
    val mapState: MapState = MapState.INIT,
    val map: ArcGISMap? = null,
    val indoorsLocationDataSource: IndoorsLocationDataSource? = null,
    val errorString: Int? = null,
    val showProgressBar: Boolean = false,
    val startStopButtonText: Int? = null,
    val startStopButtonVisibility: Boolean = false
)

data class LocationDetailsState(
    val floor: Int?,
    val positionSourceText: String?,
    val horizontalAccuracyText: Double,
    val senderCount: Int?,
    val isVisible: Boolean = true
)
