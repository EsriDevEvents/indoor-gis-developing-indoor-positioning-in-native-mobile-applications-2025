//
// COPYRIGHT 2025 ESRI
//
// TRADE SECRETS: ESRI PROPRIETARY AND CONFIDENTIAL
// Unpublished material - all rights reserved under the
// Copyright Laws of the United States and applicable international
// laws, treaties, and conventions.
//
// For additional information, contact:
// Environmental Systems Research Institute, Inc.
// Attn: Contracts and Legal Services Department
// 380 New York Street
// Redlands, California, 92373
// USA
//
// email: contracts@esri.com
//

import SwiftUI
import ArcGIS
import CoreLocation
import OSLog

let logger = os.Logger(subsystem: "com.esri.IPSExample", category: "ilds")

struct ContentView: View, ArcGISAuthenticationChallengeHandler {
    private struct LoadedMap {
        let mapView: MapView
        let ilds: IndoorsLocationDataSource
    }
    
    @State private var loadMapResult: Result<LoadedMap, Error>?
    @State private var ildsStatus = IndoorsLocationDataSource.Status.stopped
    
    @State private var info: String = ""
    
    @State private var locationTask: Task<Void, Never>?
    @State private var statusTask: Task<Void, Never>?
    @State private var errorTask: Task<Void, Never>?
    @State private var warningTask: Task<Void, Never>?
    @State private var messageTask: Task<Void, Never>?
    
    var body: some View {
        Group {
            ZStack {
                // Map view
                if let loadILDSResult = loadMapResult {
                    switch loadILDSResult {
                    case let .success(loadedILDS):
                        loadedILDS.mapView
                    case let .failure(error):
                        Text("Error: \(errorString(for: error))")
                            .padding()
                    }
                } else {
                    ProgressView()
                }
                
                // Location information view
                Text(info)
                    .font(.title3)
                    .background(.gray)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(EdgeInsets(top: 10, leading: 10, bottom: 0, trailing: 10))
                
                // Start-Stop Button
                if let loadMapResult = loadMapResult {
                    Button(action: {
                        switch loadMapResult {
                        case .failure:
                            Task {
                                await loadMap()
                            }
                            
                        case let .success(loadedMap):
                            switch loadedMap.ilds.status {
                            case .starting, .started:
                                Task {
                                    await stopILDS(loadedMap.ilds)
                                }
                                
                            case .failedToStart, .stopped, .stopping:
                                Task {
                                    await startILDS(loadedMap.ilds)
                                }
                            @unknown default:
                                break
                            }
                        }
                    }) {
                        switch loadMapResult {
                        case .failure:
                            return Text("start")
                            
                        case .success:
                            switch ildsStatus {
                            case .stopped, .starting, .failedToStart:
                                return Text("start")
                                
                            case .started, .stopping:
                                return Text("stop")
                                
                            @unknown default:
                                return Text("")
                            }
                        }
                    }
                    .font(.title)
                    .background(.blue)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(EdgeInsets(top: 0, leading: 10, bottom: 60, trailing: 10))
                }
            }
        }.task {
            let loadedMap = await loadMap()
            
            // If the map loads successfully, immediately start ILDS.
            if let loadedMap = loadedMap {
                await startILDS(loadedMap.ilds)
            }
        }.onAppear {
            ArcGISEnvironment.authenticationManager.arcGISAuthenticationChallengeHandler = self
            CLLocationManager().requestWhenInUseAuthorization()
        }
        .onDisappear {
            ArcGISEnvironment.authenticationManager.arcGISAuthenticationChallengeHandler = nil
        }
    }
    
    private enum LoadMapError: Error {
        case indoorPositioningDefinitionNotFound
    }
    
    private func loadMap() async -> LoadedMap? {
        do {
            // Load map from portal
//            let map = try await loadMapFromPortal()
            
            // Load map from MMPK
            let map = try await loadMobileMapPackage()
            
            guard let indoorPositioningDefinition = map.indoorPositioningDefinition else {
                loadMapResult = .failure(LoadMapError.indoorPositioningDefinitionNotFound)
                return nil
            }
            
            // Required for indoorPositioningDefinition.positioningTableInfo and indoorPositioningDefinition.serviceGeodatabaseURL
            try await indoorPositioningDefinition.load()
            
            switch indoorPositioningDefinition.dataOrigin {
            case .geodatabase:
                logger.info("[origin] geodatabase")
            case .positioningTable:
                let guid = indoorPositioningDefinition.positioningTableInfo!.globalID
                logger.info("[origin] positioningTable, GUID: \(guid), isBluetoothCapable: \(indoorPositioningDefinition.isBluetoothCapable), isWifiCapable: \(indoorPositioningDefinition.isWifiCapable)")
                
            case .serviceGeodatabase:
                let portalItem = PortalItem(url: indoorPositioningDefinition.serviceGeodatabaseURL!)!
                try await portalItem.load()
                
                let lastModified = portalItem.modificationDate != nil ? DateFormatter().string(from: portalItem.modificationDate!) : ""
                
                logger.info("[origin] serviceGeodatabase, title: \(portalItem.title), owner: \(portalItem.owner), isBluetoothCapable: \(indoorPositioningDefinition.isBluetoothCapable), isWifiCapable: \(indoorPositioningDefinition.isWifiCapable), lastModified: \(lastModified)")
            @unknown default:
                break
            }
            
            let ilds = IndoorsLocationDataSource(definition: indoorPositioningDefinition)
            
            // Enable streamed message updates
            ilds.configuration.infoMessagesAreEnabled = true
            
            // Assign ILDS to the map's location display
            let locationDisplay = LocationDisplay(dataSource: ilds)
            let mapView = MapView(map: map).locationDisplay(locationDisplay)
            
            let loadedMap = LoadedMap(mapView: mapView, ilds: ilds)
            loadMapResult = .success(loadedMap)
            
            return loadedMap
        } catch let error {
            loadMapResult = .failure(error)
            
            return nil
        }
    }
    
    private func loadMapFromPortal() async throws -> Map {
        let portal = Portal(url: URL(string: "https://viennardc.maps.arcgis.com")!)
        try await portal.load()
        
        let map = Map(item: PortalItem(portal: portal, id: Item.ID(rawValue: "a4ab11d9eca94692acff9580ae47a9dc")!))
        try await map.load()
        
        return map
    }
    
    private func loadMobileMapPackage() async throws -> Map {
        let url = Bundle.main.url(forResource: "Esri Vienna R_D Bluetooth deployment", withExtension: "mmpk")!
        let mobileMapPackage = MobileMapPackage(fileURL: url)
        try await mobileMapPackage.load()
        
        return mobileMapPackage.maps.first!
    }
    
    private func startILDS(_ ilds: IndoorsLocationDataSource) async {
        do {
            try await ilds.start()
            
            locationTask = Task {
                // Subscribe to the locations stream
                for await location in ilds.locations {
                    // Show updated location information
                    info = parseDetailedLocationInformation(location)
                }
            }
            
            statusTask = Task {
                // Subscribe to the streamed status updates
                for await status in ilds.$status {
                    ildsStatus = status
                    
                    switch status {
                    case .starting:
                        logger.info("[status] starting")
                    case .failedToStart:
                        logger.info("[status] failedToStart")
                    case .started:
                        logger.info("[status] started")
                    case .stopping:
                        logger.info("[status] stopping")
                    case .stopped:
                        logger.info("[status] stopped")
                        
                        // Handle UI state
                        info = ""
                    @unknown default:
                        break
                    }
                }
            }
            
            errorTask = Task {
                // Subscribe to the streamed error updates
                for await error in ilds.$error {
                    if let error = error {
                        logger.error("[error] \(error.localizedDescription)")
                    }
                }
            }
            
            warningTask = Task {
                // Subscribe to the streamed warning updates
                for await warning in ilds.$warning {
                    if let warning = warning {
                        if let arcGISError = warning as? ArcGISError {
                            logger.warning("[warning] \(arcGISError.details)")
                        } else {
                            logger.warning("[warning] \(warning.localizedDescription)")
                        }
                    }
                }
            }
            
            messageTask = Task {
                // Subscribe to the streamed message updates
                for await message in ilds.messages {
                    logger.info("[message] \(message.timestamp), \(message.message)")
                }
            }
        } catch let error {
            loadMapResult = .failure(error)
        }
    }
    
    private func stopILDS(_ ilds: IndoorsLocationDataSource) async {
        await ilds.stop()
        
        locationTask?.cancel()
        locationTask = nil
        
        statusTask?.cancel()
        statusTask = nil
        
        errorTask?.cancel()
        errorTask = nil
        
        warningTask?.cancel()
        warningTask = nil
        
        messageTask?.cancel()
        messageTask = nil
    }
    
    private func parseDetailedLocationInformation(_ location: Location) -> String {
        var info = ""
        
        // Parse new location details from additionslSourceProperties
        let positionSource = location.additionalSourceProperties[.positionSource] as! String
        info += "Source: \(positionSource)"
        
        info += "\nFloor: "
        if let floor = location.additionalSourceProperties[.floor] as? NSNumber {
            info += "\(floor.intValue)"
        } else {
            info += "unknown"
        }
        
        if positionSource == "GNSS", let satteliteCount = location.additionalSourceProperties[.satelliteCount] {
            info += "\nSatellites: \(satteliteCount)"
        } else if let transmitterCount = location.additionalSourceProperties[.transmitterCount] {
            info += "\nTransmitters: \(transmitterCount)"
        }
        
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.maximumSignificantDigits = 5
        if location.horizontalAccuracy != 0.0 {
            info += "\nHoriz. Accuracy: \(fmt.string(for: location.horizontalAccuracy)!)"
        }
        
        return info
    }
    
    private func errorString(for error: Error) -> String {
        if let authenticationError = error as? ArcGISAuthenticationError {
            switch authenticationError {
            case .credentialCannotBeShared:
                return "Credential cannot be shared"
                
            case .forbidden:
                return "Access forbidden"
                
            case .invalidAPIKey:
                return "Invalid API key"
                
            case .invalidCredentials:
                return "Invalid credentials"
                
            case .invalidToken:
                return "Invalid token"
                
            case .oAuthAuthorizationFailure(type: let type, details: let description):
                return "OAuth authorization failed. Type: \(type), Description: \(description)"
                
            case .sslRequired:
                return "SSL required"
                
            case .tokenExpired:
                return "Token expired"
                
            case .tokenRequired:
                return "Token required"
                
            case .unableToDetermineTokenURL:
                return "Unable to determine token URL"
                
            @unknown default:
                return "Unknown error"
            }
        }
        
        if let arcGISError = error as? ArcGISError {
            return arcGISError.details
        }
        
        if let loadMapError = error as? LoadMapError {
            switch loadMapError {
            case .indoorPositioningDefinitionNotFound:
                return "PositiioningDefinition not found"
            }
        }
        
        return error.localizedDescription
    }
    
    func handleArcGISAuthenticationChallenge(_ challenge: ArcGISAuthenticationChallenge) async throws -> ArcGISAuthenticationChallenge.Disposition {
        return .continueWithCredential(
            try await TokenCredential.credential(for: challenge, username: "conf_user_IPS", password: "conf_user_IPS1")
        )
    }
}
