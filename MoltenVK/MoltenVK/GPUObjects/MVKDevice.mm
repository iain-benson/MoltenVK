/*
 * MVKDevice.mm
 *
 * Copyright (c) 2014-2018 The Brenwill Workshop Ltd. (http://www.brenwill.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "MVKInstance.h"
#include "MVKDevice.h"
#include "MVKQueue.h"
#include "MVKSurface.h"
#include "MVKBuffer.h"
#include "MVKImage.h"
#include "MVKSwapchain.h"
#include "MVKQueryPool.h"
#include "MVKShaderModule.h"
#include "MVKPipeline.h"
#include "MVKFramebuffer.h"
#include "MVKRenderPass.h"
#include "MVKCommandPool.h"
#include "MVKFoundation.h"
#include "MVKEnvironment.h"
#include "MVKOSExtensions.h"
#include <MoltenVKSPIRVToMSLConverter/SPIRVToMSLConverter.h>
#include "mvk_datatypes.h"
#include "vk_mvk_moltenvk.h"

#import "CAMetalLayer+MoltenVK.h"

using namespace std;


#if MVK_IOS
#	include <UIKit/UIKit.h>
#	define MVKViewClass		UIView
#endif
#if MVK_MACOS
#	include <AppKit/AppKit.h>
#	define MVKViewClass		NSView
#endif


#pragma mark -
#pragma mark MVKPhysicalDevice

void MVKPhysicalDevice::getFeatures(VkPhysicalDeviceFeatures* features) {
    if (features) { *features = _features.features; }
}

void MVKPhysicalDevice::getFeatures2(VkPhysicalDeviceFeatures2* features) {
  if (features) { *features = _features; }
}

void MVKPhysicalDevice::getMetalFeatures(MVKPhysicalDeviceMetalFeatures* mtlFeatures) {
    if (mtlFeatures) { *mtlFeatures = _metalFeatures; }
}

void MVKPhysicalDevice::getProperties(VkPhysicalDeviceProperties* properties) {
    if (properties) { *properties = _properties.properties; }
}

void MVKPhysicalDevice::getProperties2(VkPhysicalDeviceProperties2* properties) {
  if (properties) { *properties = _properties; }
}

bool MVKPhysicalDevice::getFormatIsSupported(VkFormat format) {

	if ( !mvkVkFormatIsSupported(format) ) { return false; }

	// Special-case certain formats that not all GPU's support.
#if MVK_MACOS
	switch (mvkMTLPixelFormatFromVkFormat(format)) {
		case MTLPixelFormatDepth24Unorm_Stencil8:
			return getMTLDevice().isDepth24Stencil8PixelFormatSupported;
			break;

		default:
			break;
	}
#endif

	return true;
}

void MVKPhysicalDevice::getFormatProperties(VkFormat format, VkFormatProperties* pFormatProperties) {
    if (pFormatProperties) {
		*pFormatProperties = mvkVkFormatProperties(format, getFormatIsSupported(format));
	}
}

VkResult MVKPhysicalDevice::getImageFormatProperties(VkFormat format,
                                                     VkImageType type,
                                                     VkImageTiling tiling,
                                                     VkImageUsageFlags usage,
                                                     VkImageCreateFlags flags,
                                                     VkImageFormatProperties* pImageFormatProperties) {

	if ( !getFormatIsSupported(format) ) { return VK_ERROR_FORMAT_NOT_SUPPORTED; }

	if ( !pImageFormatProperties ) { return VK_SUCCESS; }

    VkPhysicalDeviceLimits* pLimits = &_properties.properties.limits;
    VkExtent3D maxExt;
    uint32_t maxLayers;
	uint32_t maxLevels;
    switch (type) {
        case VK_IMAGE_TYPE_1D:
			// Metal does not allow 1D textures to be used as attachments
			if (mvkIsAnyFlagEnabled(usage, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT)) {
				return VK_ERROR_FORMAT_NOT_SUPPORTED;
			}
            maxExt.width = pLimits->maxImageDimension1D;
            maxExt.height = 1;
            maxExt.depth = 1;
			maxLevels = 1;
            maxLayers = pLimits->maxImageArrayLayers;
            break;
        case VK_IMAGE_TYPE_2D:
            maxExt.width = pLimits->maxImageDimension2D;
            maxExt.height = pLimits->maxImageDimension2D;
            maxExt.depth = 1;
			maxLevels = mvkMipmapLevels3D(maxExt);
            maxLayers = pLimits->maxImageArrayLayers;
            break;
        case VK_IMAGE_TYPE_3D:
            maxExt.width = pLimits->maxImageDimension3D;
            maxExt.height = pLimits->maxImageDimension3D;
            maxExt.depth = pLimits->maxImageDimension3D;
			maxLevels = mvkMipmapLevels3D(maxExt);
            maxLayers = 1;
            break;
        default:
            maxExt = { 1, 1, 1};
            maxLayers = 1;
			maxLevels = 1;
            break;
    }

    pImageFormatProperties->maxExtent = maxExt;
    pImageFormatProperties->maxMipLevels = maxLevels;
    pImageFormatProperties->maxArrayLayers = maxLayers;
    pImageFormatProperties->sampleCounts = _metalFeatures.supportedSampleCounts;
    pImageFormatProperties->maxResourceSize = kMVKUndefinedLargeUInt64;

    return VK_SUCCESS;
}


#pragma mark Surfaces

VkResult MVKPhysicalDevice::getSurfaceSupport(uint32_t queueFamilyIndex,
											  MVKSurface* surface,
											  VkBool32* pSupported) {
    // Check whether this is a headless device
    bool isHeadless = false;
#if MVK_MACOS
    isHeadless = getMTLDevice().isHeadless;
#endif
    
	// If this device is headless or the surface does not have a CAMetalLayer, it is not supported.
    *pSupported = !(isHeadless || (surface->getCAMetalLayer() == nil));
	return *pSupported ? VK_SUCCESS : surface->getConfigurationResult();
}

VkResult MVKPhysicalDevice::getSurfaceCapabilities(MVKSurface* surface,
												   VkSurfaceCapabilitiesKHR* pSurfaceCapabilities) {

	// The layer underlying the surface view must be a CAMetalLayer.
	CAMetalLayer* mtlLayer = surface->getCAMetalLayer();
	if ( !mtlLayer ) { return surface->getConfigurationResult(); }

    VkExtent2D surfExtnt = mvkVkExtent2DFromCGSize(mtlLayer.naturalDrawableSizeMVK);

	// Metal supports 3 concurrent drawables, but if the swapchain is destroyed and
	// rebuilt as part of resizing, one will be held by the current display image.
	pSurfaceCapabilities->minImageCount = 2;
	pSurfaceCapabilities->maxImageCount = 2;

	pSurfaceCapabilities->currentExtent = surfExtnt;
	pSurfaceCapabilities->minImageExtent = surfExtnt;
	pSurfaceCapabilities->maxImageExtent = surfExtnt;
    pSurfaceCapabilities->maxImageArrayLayers = 1;
	pSurfaceCapabilities->supportedTransforms = (VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR);
	pSurfaceCapabilities->currentTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    pSurfaceCapabilities->supportedCompositeAlpha = (VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR |
                                                     VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR |
                                                     VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR);
	pSurfaceCapabilities->supportedUsageFlags = (VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                                                 VK_IMAGE_USAGE_STORAGE_BIT |
                                                 VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
												 VK_IMAGE_USAGE_TRANSFER_DST_BIT |
												 VK_IMAGE_USAGE_SAMPLED_BIT);
	return VK_SUCCESS;
}

VkResult MVKPhysicalDevice::getSurfaceFormats(MVKSurface* surface,
											  uint32_t* pCount,
											  VkSurfaceFormatKHR* pSurfaceFormats) {

	// The layer underlying the surface view must be a CAMetalLayer.
	CAMetalLayer* mtlLayer = surface->getCAMetalLayer();
	if ( !mtlLayer ) { return surface->getConfigurationResult(); }

	const MTLPixelFormat mtlFormats[] = {
		MTLPixelFormatBGRA8Unorm,
		MTLPixelFormatBGRA8Unorm_sRGB,
		MTLPixelFormatRGBA16Float,
	};

	const uint mtlFmtsCnt = sizeof(mtlFormats) / sizeof(MTLPixelFormat);

	// If properties aren't actually being requested yet, simply update the returned count
	if ( !pSurfaceFormats ) {
		*pCount = mtlFmtsCnt;
		return VK_SUCCESS;
	}

	// Determine how many results we'll return, and return that number
	VkResult result = (*pCount <= mtlFmtsCnt) ? VK_SUCCESS : VK_INCOMPLETE;
	*pCount = min(*pCount, mtlFmtsCnt);

	// Now populate the supplied array
	for (uint fmtIdx = 0; fmtIdx < *pCount; fmtIdx++) {
		pSurfaceFormats[fmtIdx].format = mvkVkFormatFromMTLPixelFormat(mtlFormats[fmtIdx]);
		pSurfaceFormats[fmtIdx].colorSpace = VK_COLORSPACE_SRGB_NONLINEAR_KHR;
	}

	return result;
}

VkResult MVKPhysicalDevice::getSurfacePresentModes(MVKSurface* surface,
												   uint32_t* pCount,
												   VkPresentModeKHR* pPresentModes) {

	// The layer underlying the surface view must be a CAMetalLayer.
	CAMetalLayer* mtlLayer = surface->getCAMetalLayer();
	if ( !mtlLayer ) { return surface->getConfigurationResult(); }

	vector<VkPresentModeKHR> presentModes;
	presentModes.push_back(VK_PRESENT_MODE_FIFO_KHR);

	if (_metalFeatures.presentModeImmediate) {
		presentModes.push_back(VK_PRESENT_MODE_IMMEDIATE_KHR);
	}

	uint32_t presentModesCnt = uint32_t(presentModes.size());

	// If properties aren't actually being requested yet, simply update the returned count
	if ( !pPresentModes ) {
		*pCount = presentModesCnt;
		return VK_SUCCESS;
	}

	// Determine how many results we'll return, and return that number
	VkResult result = (*pCount <= presentModesCnt) ? VK_SUCCESS : VK_INCOMPLETE;
	*pCount = min(*pCount, presentModesCnt);

	// Now populate the supplied array
	for (uint fmtIdx = 0; fmtIdx < *pCount; fmtIdx++) {
		pPresentModes[fmtIdx] = presentModes[fmtIdx];
	}

	return result;
}


#pragma mark Queues

VkResult MVKPhysicalDevice::getQueueFamilyProperties(uint32_t* pCount,
													 VkQueueFamilyProperties* queueProperties) {

	uint32_t qfCnt = uint32_t(_queueFamilies.size());

	// If properties aren't actually being requested yet, simply update the returned count
	if ( !queueProperties ) {
		*pCount = qfCnt;
		return VK_SUCCESS;
	}

	// Determine how many families we'll return, and return that number
	*pCount = min(*pCount, qfCnt);

	// Now populate the queue families
	if (queueProperties) {
		for (uint32_t qfIdx = 0; qfIdx < *pCount; qfIdx++) {
			_queueFamilies[qfIdx]->getProperties(&queueProperties[qfIdx]);
		}
	}

	return (*pCount <= qfCnt) ? VK_SUCCESS : VK_INCOMPLETE;
}


#pragma mark Memory models

/** Populates the specified memory properties with the memory characteristics of this device. */
VkResult MVKPhysicalDevice::getPhysicalDeviceMemoryProperties(VkPhysicalDeviceMemoryProperties* pMemoryProperties) {
	*pMemoryProperties = _memoryProperties;
	return VK_SUCCESS;
}


#pragma mark Construction

/** Initializes the Metal-specific physical device features of this instance. */
void MVKPhysicalDevice::initMetalFeatures() {
	memset(&_metalFeatures, 0, sizeof(_metalFeatures));	// Start with everything cleared

	_metalFeatures.maxPerStageBufferCount = 31;
    _metalFeatures.maxMTLBufferSize = (256 * MEBI);
    _metalFeatures.dynamicMTLBuffers = false;

    _metalFeatures.maxPerStageSamplerCount = 16;
    _metalFeatures.maxQueryBufferSize = (64 * KIBI);

	_metalFeatures.ioSurfaces = MVK_SUPPORT_IOSURFACE_BOOL;

#if MVK_IOS
    _metalFeatures.mslVersion = SPIRVToMSLConverterOptions::makeMSLVersion(1);
    _metalFeatures.maxPerStageTextureCount = 31;
    _metalFeatures.mtlBufferAlignment = 64;
	_metalFeatures.mtlCopyBufferAlignment = 1;
    _metalFeatures.texelBuffers = true;
	_metalFeatures.maxTextureDimension = (4 * KIBI);

    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily1_v2] ) {
        _metalFeatures.mslVersion = SPIRVToMSLConverterOptions::makeMSLVersion(1, 1);
        _metalFeatures.dynamicMTLBuffers = true;
		_metalFeatures.maxTextureDimension = (8 * KIBI);
    }
    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily1_v3] ) {
        _metalFeatures.mslVersion = SPIRVToMSLConverterOptions::makeMSLVersion(1, 2);
        _metalFeatures.shaderSpecialization = true;
    }
    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily1_v4] ) {
        _metalFeatures.mslVersion = SPIRVToMSLConverterOptions::makeMSLVersion(2);
    }
	if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily2_v4] ) {
		_metalFeatures.depthClipMode = true;
	}

	if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily3_v1] ) {
		_metalFeatures.indirectDrawing = true;
		_metalFeatures.baseVertexInstanceDrawing = true;
		_metalFeatures.mtlBufferAlignment = 16;     // Min float4 alignment for typical vertex buffers. MTLBuffer may go down to 4 bytes for other data.
		_metalFeatures.maxTextureDimension = (16 * KIBI);
	}
#endif

#if MVK_MACOS
    _metalFeatures.mslVersion = SPIRVToMSLConverterOptions::makeMSLVersion(1, 1);
    _metalFeatures.maxPerStageTextureCount = 128;
    _metalFeatures.mtlBufferAlignment = 256;
	_metalFeatures.mtlCopyBufferAlignment = 4;
	_metalFeatures.indirectDrawing = true;
	_metalFeatures.baseVertexInstanceDrawing = true;
    _metalFeatures.depthClipMode = true;
	_metalFeatures.layeredRendering = true;
	_metalFeatures.maxTextureDimension = (16 * KIBI);

    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_macOS_GPUFamily1_v2] ) {
        _metalFeatures.mslVersion = SPIRVToMSLConverterOptions::makeMSLVersion(1, 2);
        _metalFeatures.dynamicMTLBuffers = true;
        _metalFeatures.shaderSpecialization = true;
        _metalFeatures.maxMTLBufferSize = (1 * GIBI);
    }

    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_macOS_GPUFamily1_v3] ) {
        _metalFeatures.mslVersion = SPIRVToMSLConverterOptions::makeMSLVersion(2);
        _metalFeatures.texelBuffers = true;
		_metalFeatures.presentModeImmediate = true;
    }
#endif

    for (uint32_t sc = VK_SAMPLE_COUNT_1_BIT; sc <= VK_SAMPLE_COUNT_64_BIT; sc <<= 1) {
        if ([_mtlDevice supportsTextureSampleCount: mvkSampleCountFromVkSampleCountFlagBits((VkSampleCountFlagBits)sc)]) {
            _metalFeatures.supportedSampleCounts |= sc;
        }
    }
}

/** Initializes the physical device features of this instance. */
void MVKPhysicalDevice::initFeatures() {
	memset(&_features.features, 0, sizeof(_features.features));	// Start with everything cleared

  
    _features.pNext = nullptr;
    _features.sType = VkStructureType::VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
  
    _features.features.independentBlend = true;
    _features.features.depthBiasClamp = true;
    _features.features.fillModeNonSolid = true;
    _features.features.largePoints = true;
    _features.features.alphaToOne = true;
    _features.features.samplerAnisotropy = true;
    _features.features.shaderImageGatherExtended = true;
    _features.features.shaderStorageImageExtendedFormats = true;
    _features.features.shaderClipDistance = true;
    _features.features.shaderInt16 = true;
	  _features.features.multiDrawIndirect = true;

#if MVK_IOS
    _features.features.textureCompressionETC2 = true;

    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily2_v1] ) {
        _features.features.textureCompressionASTC_LDR = true;
    }

    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily3_v1] ) {
        _features.features.occlusionQueryPrecise = true;
    }
#endif

#if MVK_MACOS
    _features.features.textureCompressionBC = true;
    _features.features.occlusionQueryPrecise = true;
    _features.features.imageCubeArray = true;
    _features.features.depthClamp = true;
    _features.features.vertexPipelineStoresAndAtomics = true;
    _features.features.fragmentStoresAndAtomics = true;

    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_macOS_GPUFamily1_v2] ) {
        _features.features.dualSrcBlend = true;
    }

#endif
  
  // Need support adding for DirectX!
  // DX9_1
  _features.features.sampleRateShading = true;
  _features.features.shaderCullDistance = true;
  _features.features.robustBufferAccess = true;
  
  // DX9_3
  _features.features.multiViewport = true;
  
  // DX10_1
  _features.features.fullDrawIndexUint32 = true;
  _features.features.geometryShader = true;
  _features.features.logicOp = true;
  _features.features.shaderImageGatherExtended = true;
  
  // DX11_0
  _features.features.drawIndirectFirstInstance = true;
  _features.features.tessellationShader = true;
  _features.features.shaderStorageImageWriteWithoutFormat = true;
}


#pragma mark VkPhysicalDeviceFeatures - List of features available on the device

//typedef struct VkPhysicalDeviceFeatures {
//    VkBool32    robustBufferAccess;
//    VkBool32    fullDrawIndexUint32;
//    VkBool32    imageCubeArray;                               // done
//    VkBool32    independentBlend;                             // done
//    VkBool32    geometryShader;
//    VkBool32    tessellationShader;
//    VkBool32    sampleRateShading;
//    VkBool32    dualSrcBlend;                                 // done
//    VkBool32    logicOp;
//    VkBool32    multiDrawIndirect;							// done
//    VkBool32    drawIndirectFirstInstance;
//    VkBool32    depthClamp;                                   // done
//    VkBool32    depthBiasClamp;                               // done
//    VkBool32    fillModeNonSolid;                             // done
//    VkBool32    depthBounds;
//    VkBool32    wideLines;
//    VkBool32    largePoints;                                  // done
//    VkBool32    alphaToOne;                                   // done
//    VkBool32    multiViewport;
//    VkBool32    samplerAnisotropy;                            // done
//    VkBool32    textureCompressionETC2;                       // done
//    VkBool32    textureCompressionASTC_LDR;                   // done
//    VkBool32    textureCompressionBC;                         // done
//    VkBool32    occlusionQueryPrecise;                        // done
//    VkBool32    pipelineStatisticsQuery;
//    VkBool32    vertexPipelineStoresAndAtomics;               // done
//    VkBool32    fragmentStoresAndAtomics;                     // done
//    VkBool32    shaderTessellationAndGeometryPointSize;
//    VkBool32    shaderImageGatherExtended;                    // done
//    VkBool32    shaderStorageImageExtendedFormats;            // done
//    VkBool32    shaderStorageImageMultisample;
//    VkBool32    shaderStorageImageReadWithoutFormat;
//    VkBool32    shaderStorageImageWriteWithoutFormat;
//    VkBool32    shaderUniformBufferArrayDynamicIndexing;
//    VkBool32    shaderSampledImageArrayDynamicIndexing;
//    VkBool32    shaderStorageBufferArrayDynamicIndexing;
//    VkBool32    shaderStorageImageArrayDynamicIndexing;
//    VkBool32    shaderClipDistance;                           // done
//    VkBool32    shaderCullDistance;
//    VkBool32    shaderFloat64;
//    VkBool32    shaderInt64;
//    VkBool32    shaderInt16;                                  // done
//    VkBool32    shaderResourceResidency;
//    VkBool32    shaderResourceMinLod;
//    VkBool32    sparseBinding;
//    VkBool32    sparseResidencyBuffer;
//    VkBool32    sparseResidencyImage2D;
//    VkBool32    sparseResidencyImage3D;
//    VkBool32    sparseResidency2Samples;
//    VkBool32    sparseResidency4Samples;
//    VkBool32    sparseResidency8Samples;
//    VkBool32    sparseResidency16Samples;
//    VkBool32    sparseResidencyAliased;
//    VkBool32    variableMultisampleRate;
//    VkBool32    inheritedQueries;
//} VkPhysicalDeviceFeatures;

/** Initializes the physical device properties of this instance. */
void MVKPhysicalDevice::initProperties() {
	memset(&_properties.properties, 0, sizeof(_properties.properties));	// Start with everything cleared

  _properties.pNext = nullptr;
  _properties.sType = VkStructureType::VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;

	_properties.properties.apiVersion = MVK_VULKAN_API_VERSION;
	_properties.properties.driverVersion = MVK_VERSION;

	mvkPopulateGPUInfo(_properties.properties, _mtlDevice);
	initPipelineCacheUUID();

	// Limits
#if MVK_IOS
    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily2_v1] ) {
        _properties.properties.limits.maxColorAttachments = 8;
    } else {
        _properties.properties.limits.maxColorAttachments = 4;
    }
#endif
#if MVK_MACOS
    _properties.properties.limits.maxColorAttachments = 8;
#endif

    _properties.properties.limits.maxFragmentOutputAttachments = _properties.properties.limits.maxColorAttachments;
    _properties.properties.limits.maxFragmentDualSrcAttachments = _properties.properties.limits.maxFragmentOutputAttachments;

	_properties.properties.limits.framebufferColorSampleCounts = _metalFeatures.supportedSampleCounts;
	_properties.properties.limits.framebufferDepthSampleCounts = _metalFeatures.supportedSampleCounts;
	_properties.properties.limits.framebufferStencilSampleCounts = _metalFeatures.supportedSampleCounts;
	_properties.properties.limits.framebufferNoAttachmentsSampleCounts = _metalFeatures.supportedSampleCounts;
	_properties.properties.limits.sampledImageColorSampleCounts = _metalFeatures.supportedSampleCounts;
	_properties.properties.limits.sampledImageIntegerSampleCounts = _metalFeatures.supportedSampleCounts;
	_properties.properties.limits.sampledImageDepthSampleCounts = _metalFeatures.supportedSampleCounts;
	_properties.properties.limits.sampledImageStencilSampleCounts = _metalFeatures.supportedSampleCounts;
	_properties.properties.limits.storageImageSampleCounts = _metalFeatures.supportedSampleCounts;

	_properties.properties.limits.maxImageDimension1D = _metalFeatures.maxTextureDimension;
	_properties.properties.limits.maxImageDimension2D = _metalFeatures.maxTextureDimension;
	_properties.properties.limits.maxImageDimensionCube = _metalFeatures.maxTextureDimension;
	_properties.properties.limits.maxFramebufferWidth = _metalFeatures.maxTextureDimension;
	_properties.properties.limits.maxFramebufferHeight = _metalFeatures.maxTextureDimension;
	_properties.properties.limits.maxFramebufferLayers = 256;

    _properties.properties.limits.maxViewportDimensions[0] = _metalFeatures.maxTextureDimension;
    _properties.properties.limits.maxViewportDimensions[1] = _metalFeatures.maxTextureDimension;
    float maxVPDim = max(_properties.properties.limits.maxViewportDimensions[0], _properties.properties.limits.maxViewportDimensions[1]);
    _properties.properties.limits.viewportBoundsRange[0] = (-2.0 * maxVPDim);
    _properties.properties.limits.viewportBoundsRange[1] = (2.0 * maxVPDim) - 1;

	_properties.properties.limits.maxImageDimension3D = (2 * KIBI);
	_properties.properties.limits.maxImageArrayLayers = (2 * KIBI);
	_properties.properties.limits.maxViewports = 1;
	_properties.properties.limits.maxSamplerAnisotropy = 16;

    _properties.properties.limits.maxVertexInputAttributes = 31;
    _properties.properties.limits.maxVertexInputBindings = 31;

    _properties.properties.limits.maxVertexInputAttributeOffset = (4 * KIBI);
    _properties.properties.limits.maxVertexInputBindingStride = _properties.properties.limits.maxVertexInputAttributeOffset - 1;

	_properties.properties.limits.maxPerStageDescriptorSamplers = _metalFeatures.maxPerStageSamplerCount;
	_properties.properties.limits.maxPerStageDescriptorUniformBuffers = _metalFeatures.maxPerStageBufferCount;
	_properties.properties.limits.maxPerStageDescriptorStorageBuffers = _metalFeatures.maxPerStageBufferCount;
	_properties.properties.limits.maxPerStageDescriptorSampledImages = _metalFeatures.maxPerStageTextureCount;
	_properties.properties.limits.maxPerStageDescriptorStorageImages = _metalFeatures.maxPerStageTextureCount;
	_properties.properties.limits.maxPerStageDescriptorInputAttachments = _metalFeatures.maxPerStageTextureCount;

    _properties.properties.limits.maxPerStageResources = (_metalFeatures.maxPerStageBufferCount + _metalFeatures.maxPerStageTextureCount);
    _properties.properties.limits.maxFragmentCombinedOutputResources = _properties.properties.limits.maxPerStageResources;

	_properties.properties.limits.maxDescriptorSetSamplers = (_properties.properties.limits.maxPerStageDescriptorSamplers * 2);
	_properties.properties.limits.maxDescriptorSetUniformBuffers = (_properties.properties.limits.maxPerStageDescriptorUniformBuffers * 2);
	_properties.properties.limits.maxDescriptorSetUniformBuffersDynamic = (_properties.properties.limits.maxPerStageDescriptorUniformBuffers * 2);
	_properties.properties.limits.maxDescriptorSetStorageBuffers = (_properties.properties.limits.maxPerStageDescriptorStorageBuffers * 2);
	_properties.properties.limits.maxDescriptorSetStorageBuffersDynamic = (_properties.properties.limits.maxPerStageDescriptorStorageBuffers * 2);
	_properties.properties.limits.maxDescriptorSetSampledImages = (_properties.properties.limits.maxPerStageDescriptorSampledImages * 2);
	_properties.properties.limits.maxDescriptorSetStorageImages = (_properties.properties.limits.maxPerStageDescriptorStorageImages * 2);
	_properties.properties.limits.maxDescriptorSetInputAttachments = (_properties.properties.limits.maxPerStageDescriptorInputAttachments * 2);

	_properties.properties.limits.maxTexelBufferElements = _properties.properties.limits.maxImageDimension2D * _properties.properties.limits.maxImageDimension2D;
	_properties.properties.limits.maxUniformBufferRange = (uint32_t)_metalFeatures.maxMTLBufferSize;
	_properties.properties.limits.maxStorageBufferRange = (uint32_t)_metalFeatures.maxMTLBufferSize;
	_properties.properties.limits.maxPushConstantsSize = (4 * KIBI);

    _properties.properties.limits.minMemoryMapAlignment = _metalFeatures.mtlBufferAlignment;
    _properties.properties.limits.minTexelBufferOffsetAlignment = _metalFeatures.mtlBufferAlignment;
    _properties.properties.limits.minUniformBufferOffsetAlignment = _metalFeatures.mtlBufferAlignment;
    _properties.properties.limits.minStorageBufferOffsetAlignment = _metalFeatures.mtlBufferAlignment;
    _properties.properties.limits.bufferImageGranularity = _metalFeatures.mtlBufferAlignment;
    _properties.properties.limits.nonCoherentAtomSize = _metalFeatures.mtlBufferAlignment;

#if MVK_IOS
    _properties.properties.limits.maxFragmentInputComponents = 60;

    if ([_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily3_v1]) {
        _properties.properties.limits.optimalBufferCopyOffsetAlignment = 16;
    } else {
        _properties.properties.limits.optimalBufferCopyOffsetAlignment = 64;
    }
#endif
#if MVK_MACOS
    _properties.properties.limits.maxFragmentInputComponents = 128;
    _properties.properties.limits.optimalBufferCopyOffsetAlignment = 256;
#endif

    _properties.properties.limits.maxVertexOutputComponents = _properties.properties.limits.maxFragmentInputComponents;

    _properties.properties.limits.optimalBufferCopyRowPitchAlignment = 1;

	_properties.properties.limits.timestampComputeAndGraphics = VK_TRUE;
	_properties.properties.limits.timestampPeriod = mvkGetTimestampPeriod();

    _properties.properties.limits.pointSizeRange[0] = 1;
    _properties.properties.limits.pointSizeRange[1] = 511;
    _properties.properties.limits.pointSizeGranularity = 1;
    _properties.properties.limits.lineWidthRange[0] = 1;
    _properties.properties.limits.lineWidthRange[1] = 1;
    _properties.properties.limits.pointSizeGranularity = 1;

    _properties.properties.limits.standardSampleLocations = VK_FALSE;
    _properties.properties.limits.strictLines = VK_FALSE;

	VkExtent3D wgSize = mvkVkExtent3DFromMTLSize(_mtlDevice.maxThreadsPerThreadgroup);
	_properties.properties.limits.maxComputeWorkGroupSize[0] = wgSize.width;
	_properties.properties.limits.maxComputeWorkGroupSize[1] = wgSize.height;
	_properties.properties.limits.maxComputeWorkGroupSize[2] = wgSize.depth;
	_properties.properties.limits.maxComputeWorkGroupInvocations = max({wgSize.width, wgSize.height, wgSize.depth});

	if ( [_mtlDevice respondsToSelector: @selector(maxThreadgroupMemoryLength)] ) {
		_properties.properties.limits.maxComputeSharedMemorySize = (uint32_t)_mtlDevice.maxThreadgroupMemoryLength;
	} else {
#if MVK_IOS
		if ([_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily4_v1]) {
			_properties.properties.limits.maxComputeSharedMemorySize = (32 * KIBI);
		} else if ([_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily3_v1]) {
			_properties.properties.limits.maxComputeSharedMemorySize = (16 * KIBI);
		} else {
			_properties.properties.limits.maxComputeSharedMemorySize = ((16 * KIBI) - 32);
		}
#endif
#if MVK_MACOS
		_properties.properties.limits.maxComputeSharedMemorySize = (32 * KIBI);
#endif
	}

    // Features with no specific limits - default to unlimited int values

    _properties.properties.limits.maxMemoryAllocationCount = kMVKUndefinedLargeUInt32;
    _properties.properties.limits.maxSamplerAllocationCount = kMVKUndefinedLargeUInt32;
    _properties.properties.limits.maxBoundDescriptorSets = kMVKUndefinedLargeUInt32;

    _properties.properties.limits.maxComputeWorkGroupCount[0] = kMVKUndefinedLargeUInt32;
    _properties.properties.limits.maxComputeWorkGroupCount[1] = kMVKUndefinedLargeUInt32;
    _properties.properties.limits.maxComputeWorkGroupCount[2] = kMVKUndefinedLargeUInt32;

    _properties.properties.limits.maxDrawIndexedIndexValue = numeric_limits<uint32_t>::max() - 1;
    _properties.properties.limits.maxDrawIndirectCount = kMVKUndefinedLargeUInt32;

    _properties.properties.limits.minTexelOffset = -8;
    _properties.properties.limits.maxTexelOffset = 7;
    _properties.properties.limits.minTexelGatherOffset = _properties.properties.limits.minTexelOffset;
    _properties.properties.limits.maxTexelGatherOffset = _properties.properties.limits.maxTexelOffset;

    _properties.properties.limits.maxClipDistances = kMVKUndefinedLargeUInt32;
	_properties.properties.limits.maxCullDistances = 0;	// unsupported
    _properties.properties.limits.maxCombinedClipAndCullDistances = _properties.properties.limits.maxClipDistances +
														 _properties.properties.limits.maxCullDistances;


    // Features with unknown limits - default to Vulkan required limits
    
    _properties.properties.limits.subPixelPrecisionBits = 4;
    _properties.properties.limits.subTexelPrecisionBits = 4;
    _properties.properties.limits.mipmapPrecisionBits = 4;
    _properties.properties.limits.viewportSubPixelBits = 0;

    _properties.properties.limits.maxSamplerLodBias = 2;

    _properties.properties.limits.maxSampleMaskWords = 1;

    _properties.properties.limits.discreteQueuePriorities = 2;


    // Unsupported features - set to zeros generally

    _properties.properties.limits.sparseAddressSpaceSize = 0;

    _properties.properties.limits.maxTessellationGenerationLevel = 0;
    _properties.properties.limits.maxTessellationPatchSize = 0;
    _properties.properties.limits.maxTessellationControlPerVertexInputComponents = 0;
    _properties.properties.limits.maxTessellationControlPerVertexOutputComponents = 0;
    _properties.properties.limits.maxTessellationControlPerPatchOutputComponents = 0;
    _properties.properties.limits.maxTessellationControlTotalOutputComponents = 0;
    _properties.properties.limits.maxTessellationEvaluationInputComponents = 0;
    _properties.properties.limits.maxTessellationEvaluationOutputComponents = 0;

    _properties.properties.limits.maxGeometryShaderInvocations = 0;
    _properties.properties.limits.maxGeometryInputComponents = 0;
    _properties.properties.limits.maxGeometryOutputComponents = 0;
    _properties.properties.limits.maxGeometryOutputVertices = 0;
    _properties.properties.limits.maxGeometryTotalOutputComponents = 0;

    _properties.properties.limits.minInterpolationOffset = 0.0;
    _properties.properties.limits.maxInterpolationOffset = 0.0;
    _properties.properties.limits.subPixelInterpolationOffsetBits = 0;
}


#pragma mark VkPhysicalDeviceLimits - List of feature limits available on the device

//typedef struct VkPhysicalDeviceLimits {
//	uint32_t                                    maxImageDimension1D;                                // done
//	uint32_t                                    maxImageDimension2D;                                // done
//	uint32_t                                    maxImageDimension3D;                                // done
//	uint32_t                                    maxImageDimensionCube;                              // done
//	uint32_t                                    maxImageArrayLayers;                                // done
//	uint32_t                                    maxTexelBufferElements;                             // done
//	uint32_t                                    maxUniformBufferRange;                              // done
//	uint32_t                                    maxStorageBufferRange;                              // done
//	uint32_t                                    maxPushConstantsSize;                               // done
//	uint32_t                                    maxMemoryAllocationCount;                           // done
//	uint32_t                                    maxSamplerAllocationCount;                          // done
//	VkDeviceSize                                bufferImageGranularity;                             // done
//	VkDeviceSize                                sparseAddressSpaceSize;                             // done
//	uint32_t                                    maxBoundDescriptorSets;                             // done
//	uint32_t                                    maxPerStageDescriptorSamplers;				        // done
//	uint32_t                                    maxPerStageDescriptorUniformBuffers;		        // done
//	uint32_t                                    maxPerStageDescriptorStorageBuffers;		        // done
//	uint32_t                                    maxPerStageDescriptorSampledImages;			        // done
//	uint32_t                                    maxPerStageDescriptorStorageImages;			        // done
//	uint32_t                                    maxPerStageDescriptorInputAttachments;		        // done
//	uint32_t                                    maxPerStageResources;                               // done
//	uint32_t                                    maxDescriptorSetSamplers;					        // done
//	uint32_t                                    maxDescriptorSetUniformBuffers;				        // done
//	uint32_t                                    maxDescriptorSetUniformBuffersDynamic;		        // done
//	uint32_t                                    maxDescriptorSetStorageBuffers;				        // done
//	uint32_t                                    maxDescriptorSetStorageBuffersDynamic;		        // done
//	uint32_t                                    maxDescriptorSetSampledImages;				        // done
//	uint32_t                                    maxDescriptorSetStorageImages;				        // done
//	uint32_t                                    maxDescriptorSetInputAttachments;                   // done
//	uint32_t                                    maxVertexInputAttributes;                           // done
//	uint32_t                                    maxVertexInputBindings;                             // done
//	uint32_t                                    maxVertexInputAttributeOffset;                      // done
//	uint32_t                                    maxVertexInputBindingStride;                        // done
//	uint32_t                                    maxVertexOutputComponents;                          // done
//	uint32_t                                    maxTessellationGenerationLevel;                     // done
//	uint32_t                                    maxTessellationPatchSize;                           // done
//	uint32_t                                    maxTessellationControlPerVertexInputComponents;     // done
//	uint32_t                                    maxTessellationControlPerVertexOutputComponents;    // done
//	uint32_t                                    maxTessellationControlPerPatchOutputComponents;     // done
//	uint32_t                                    maxTessellationControlTotalOutputComponents;        // done
//	uint32_t                                    maxTessellationEvaluationInputComponents;           // done
//	uint32_t                                    maxTessellationEvaluationOutputComponents;          // done
//	uint32_t                                    maxGeometryShaderInvocations;                       // done
//	uint32_t                                    maxGeometryInputComponents;                         // done
//	uint32_t                                    maxGeometryOutputComponents;                        // done
//	uint32_t                                    maxGeometryOutputVertices;                          // done
//	uint32_t                                    maxGeometryTotalOutputComponents;                   // done
//	uint32_t                                    maxFragmentInputComponents;                         // done
//	uint32_t                                    maxFragmentOutputAttachments;                       // done
//	uint32_t                                    maxFragmentDualSrcAttachments;                      // done
//	uint32_t                                    maxFragmentCombinedOutputResources;                 // done
//	uint32_t                                    maxComputeSharedMemorySize;                         // done
//	uint32_t                                    maxComputeWorkGroupCount[3];                        // done
//	uint32_t                                    maxComputeWorkGroupInvocations;                     // done
//	uint32_t                                    maxComputeWorkGroupSize[3];                         // done
//	uint32_t                                    subPixelPrecisionBits;                              // done
//	uint32_t                                    subTexelPrecisionBits;                              // done
//	uint32_t                                    mipmapPrecisionBits;                                // done
//	uint32_t                                    maxDrawIndexedIndexValue;                           // done
//	uint32_t                                    maxDrawIndirectCount;                               // done
//	float                                       maxSamplerLodBias;                                  // done
//	float                                       maxSamplerAnisotropy;						        // done
//	uint32_t                                    maxViewports;								        // done
//	uint32_t                                    maxViewportDimensions[2];					        // done
//	float                                       viewportBoundsRange[2];                             // done
//	uint32_t                                    viewportSubPixelBits;                               // done
//	size_t                                      minMemoryMapAlignment;						        // done
//	VkDeviceSize                                minTexelBufferOffsetAlignment;				        // done
//	VkDeviceSize                                minUniformBufferOffsetAlignment;			        // done
//	VkDeviceSize                                minStorageBufferOffsetAlignment;			        // done
//	int32_t                                     minTexelOffset;                                     // done
//	uint32_t                                    maxTexelOffset;                                     // done
//	int32_t                                     minTexelGatherOffset;                               // done
//	uint32_t                                    maxTexelGatherOffset;                               // done
//	float                                       minInterpolationOffset;                             // done
//	float                                       maxInterpolationOffset;                             // done
//	uint32_t                                    subPixelInterpolationOffsetBits;			        // done
//	uint32_t                                    maxFramebufferWidth;						        // done
//	uint32_t                                    maxFramebufferHeight;						        // done
//	uint32_t                                    maxFramebufferLayers;						        // done
//	VkSampleCountFlags                          framebufferColorSampleCounts;				        // done
//	VkSampleCountFlags                          framebufferDepthSampleCounts;				        // done
//	VkSampleCountFlags                          framebufferStencilSampleCounts;				        // done
//	VkSampleCountFlags                          framebufferNoAttachmentsSampleCounts;		        // done
//	uint32_t                                    maxColorAttachments;						        // done
//	VkSampleCountFlags                          sampledImageColorSampleCounts;				        // done
//	VkSampleCountFlags                          sampledImageIntegerSampleCounts;			        // done
//	VkSampleCountFlags                          sampledImageDepthSampleCounts;				        // done
//	VkSampleCountFlags                          sampledImageStencilSampleCounts;			        // done
//	VkSampleCountFlags                          storageImageSampleCounts;					        // done
//	uint32_t                                    maxSampleMaskWords;                                 // done
//	VkBool32                                    timestampComputeAndGraphics;                        // done
//	float                                       timestampPeriod;							        // done
//	uint32_t                                    maxClipDistances;                                   // done
//	uint32_t                                    maxCullDistances;                                   // done
//	uint32_t                                    maxCombinedClipAndCullDistances;                    // done
//	uint32_t                                    discreteQueuePriorities;                            // done
//	float                                       pointSizeRange[2];                                  // done
//	float                                       lineWidthRange[2];                                  // done
//	float                                       pointSizeGranularity;                               // done
//	float                                       lineWidthGranularity;                               // done
//	VkBool32                                    strictLines;                                        // done
//	VkBool32                                    standardSampleLocations;                            // done
//	VkDeviceSize                                optimalBufferCopyOffsetAlignment;			        // done
//	VkDeviceSize                                optimalBufferCopyRowPitchAlignment;			        // done
//	VkDeviceSize                                nonCoherentAtomSize;                                // done
//} VkPhysicalDeviceLimits;

//typedef struct {
//	VkBool32                                    residencyStandard2DBlockShape;
//	VkBool32                                    residencyStandard2DMSBlockShape;
//	VkBool32                                    residencyStandard3DBlockShape;
//	VkBool32                                    residencyAlignedMipSize;
//	VkBool32                                    residencyNonResident;
//	VkBool32                                    residencyNonResidentStrict;
//} VkPhysicalDeviceSparseProperties;


void MVKPhysicalDevice::initPipelineCacheUUID() {
	size_t uuidSize = sizeof(_properties.properties.pipelineCacheUUID);

	// Clear the UUID
	memset(&_properties.properties.pipelineCacheUUID, 0, uuidSize);

	uint32_t uuidComponent;
	size_t uuidComponentSize = sizeof(uint32_t);

	size_t uuidComponentOffset = uuidSize;

	// Lower 4 bytes contains MoltenVK version
	uuidComponent = MVK_VERSION;
	uuidComponentOffset -= uuidComponentSize;
	*(uint32_t*)&_properties.properties.pipelineCacheUUID[uuidComponentOffset] = NSSwapHostIntToBig(uuidComponent);

	// Next 4 bytes contains hightest Metal feature set supported by this device
	uuidComponent = (uint32_t)getHighestMTLFeatureSet();
	uuidComponentOffset -= uuidComponentSize;
	*(uint32_t*)&_properties.properties.pipelineCacheUUID[uuidComponentOffset] = NSSwapHostIntToBig(uuidComponent);
}

MTLFeatureSet MVKPhysicalDevice::getHighestMTLFeatureSet() {
#if MVK_IOS
	MTLFeatureSet maxFS = MTLFeatureSet_iOS_GPUFamily4_v1;
	MTLFeatureSet minFS = MTLFeatureSet_iOS_GPUFamily1_v1;
#endif

#if MVK_MACOS
	MTLFeatureSet maxFS = MTLFeatureSet_macOS_GPUFamily1_v3;
	MTLFeatureSet minFS = MTLFeatureSet_macOS_GPUFamily1_v1;
#endif

	for (NSUInteger fs = maxFS; fs > minFS; fs--) {
		MTLFeatureSet mtlFS = (MTLFeatureSet)fs;
		if ( [_mtlDevice supportsFeatureSet: mtlFS] ) {
			return mtlFS;
		}
	}

	return minFS;
}

/** Initializes the memory properties of this instance. */
void MVKPhysicalDevice::initMemoryProperties() {

	// Metal Shared:
	//	- applies to both buffers and textures
	//	- default mode for buffers on both iOS & macOS
	//	- default mode for textures on iOS
	//	- one copy of memory visible to both CPU & GPU
	//	- coherent at command buffer boundaries
	// Metal Private:
	//	- applies to both buffers and textures
	//	- accessed only by GPU through render, compute, or BLIT operations
	//	- no access by CPU
	//	- always use for framebuffers and renderable textures
	// Metal Managed:
	//	- applies to both buffers and textures
	//	- default mode for textures on macOS
	//	- two copies of each buffer or texture when discrete memory available
	//	- convenience of shared mode, performance of private mode
	//	- on unified systems behaves like shared memory and has only one copy of content
	//	- when writing, use:
	//		- buffer didModifyRange:
	//		- texture replaceRegion:
	//	- when reading, use:
	//		- encoder synchronizeResource: followed by
	//		- cmdbuff waitUntilCompleted (or completion handler)
	//		- buffer/texture getBytes:

	_memoryProperties.memoryHeapCount = 1;
	_memoryProperties.memoryHeaps[0].flags = (VK_MEMORY_HEAP_DEVICE_LOCAL_BIT);
	_memoryProperties.memoryHeaps[0].size = (VkDeviceSize)mvkRecommendedMaxWorkingSetSize(_mtlDevice);
	_memoryProperties.memoryTypes[0].heapIndex = 0;
	_memoryProperties.memoryTypes[0].propertyFlags = MVK_VK_MEMORY_TYPE_METAL_PRIVATE;	// Private storage
	_memoryProperties.memoryTypes[1].heapIndex = 0;
	_memoryProperties.memoryTypes[1].propertyFlags = MVK_VK_MEMORY_TYPE_METAL_SHARED;	// Shared storage
	_memoryProperties.memoryTypes[2].heapIndex = 0;
	_memoryProperties.memoryTypes[2].propertyFlags = MVK_VK_MEMORY_TYPE_METAL_MANAGED;	// Managed storage

#if MVK_MACOS
	_memoryProperties.memoryTypeCount = 3;
	_privateMemoryTypes		= 0x1;				// Private only
	_hostVisibleMemoryTypes	= 0x6;				// Shared & managed
	_allMemoryTypes			= 0x7;				// Private, shared, & managed
#endif
#if MVK_IOS
	_memoryProperties.memoryTypeCount = 2;		// Managed storage not available on iOS
	_privateMemoryTypes		= 0x1;				// Private only
	_hostVisibleMemoryTypes	= 0x2;				// Shared only
	_allMemoryTypes			= 0x3;				// Private & shared
#endif
}

void MVKPhysicalDevice::logGPUInfo() {
	string devTypeStr;
	switch (_properties.properties.deviceType) {
		case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU:
			devTypeStr = "Discrete";
			break;
		case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU:
			devTypeStr = "Integrated";
			break;
		case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU:
			devTypeStr = "Virtual";
			break;
		case VK_PHYSICAL_DEVICE_TYPE_CPU:
			devTypeStr = "CPU Emulation";
			break;
		default:
			devTypeStr = "Unknown";
			break;
	}

	string fsMsg = "GPU device:";
	fsMsg += "\n\t\tmodel: %s";
	fsMsg += "\n\t\ttype: %s";
	fsMsg += "\n\t\tvendorID: %#06x";
	fsMsg += "\n\t\tdeviceID: %#06x";
	fsMsg += "\n\t\tpipelineCacheUUID: %s";
	fsMsg += "\n\tsupports the following Metal Feature Sets:";

#if MVK_IOS
    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily4_v1] ) { fsMsg += "\n\tviOS GPU Family 4 v1"; }

    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily3_v3] ) { fsMsg += "\n\t\tiOS GPU Family 3 v3"; }
    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily3_v2] ) { fsMsg += "\n\t\tiOS GPU Family 3 v2"; }
    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily3_v1] ) { fsMsg += "\n\t\tiOS GPU Family 3 v1"; }

    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily2_v4] ) { fsMsg += "\n\t\tiOS GPU Family 2 v4"; }
    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily2_v3] ) { fsMsg += "\n\t\tiOS GPU Family 2 v3"; }
    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily2_v2] ) { fsMsg += "\n\t\tiOS GPU Family 2 v2"; }
    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily2_v1] ) { fsMsg += "\n\t\tiOS GPU Family 2 v1"; }

    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily1_v4] ) { fsMsg += "\n\t\tiOS GPU Family 1 v4"; }
    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily1_v3] ) { fsMsg += "\n\t\tiOS GPU Family 1 v3"; }
    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily1_v2] ) { fsMsg += "\n\t\tiOS GPU Family 1 v2"; }
    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily1_v1] ) { fsMsg += "\n\t\tiOS GPU Family 1 v1"; }
#endif

#if MVK_MACOS
    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_macOS_GPUFamily1_v3] ) { fsMsg += "\n\t\tmacOS GPU Family 1 v3"; }
    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_macOS_GPUFamily1_v2] ) { fsMsg += "\n\t\tmacOS GPU Family 1 v2"; }
    if ( [_mtlDevice supportsFeatureSet: MTLFeatureSet_macOS_GPUFamily1_v1] ) { fsMsg += "\n\t\tmacOS GPU Family 1 v1"; }
#endif

	MVKLogInfo(fsMsg.c_str(), _properties.properties.deviceName, devTypeStr.c_str(), _properties.properties.vendorID, _properties.properties.deviceID,
			   [[[NSUUID alloc] initWithUUIDBytes: _properties.properties.pipelineCacheUUID] autorelease].UUIDString.UTF8String);
}

/** Initializes the queue families supported by this instance. */
void MVKPhysicalDevice::initQueueFamilies() {

	// TODO: determine correct values
	VkQueueFamilyProperties qfProps;
	qfProps.queueFlags = (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT | VK_QUEUE_TRANSFER_BIT);
	qfProps.queueCount = 8;
	qfProps.timestampValidBits = 64;
	qfProps.minImageTransferGranularity = { 1, 1, 1};

	uint32_t qfCount = 1;
	for (uint32_t qfIdx = 0; qfIdx < qfCount; qfIdx++) {
		_queueFamilies.push_back(new MVKQueueFamily(this, qfIdx, &qfProps));
	}
}

MVKPhysicalDevice::MVKPhysicalDevice(MVKInstance* mvkInstance, id<MTLDevice> mtlDevice) {
	_mvkInstance = mvkInstance;
	_mtlDevice = [mtlDevice retain];

    initMetalFeatures();        // Call first.
	initFeatures();             // Call second.
	initProperties();           // Call third.
	initMemoryProperties();
	initQueueFamilies();
	logGPUInfo();
}

MVKPhysicalDevice::~MVKPhysicalDevice() {
	mvkDestroyContainerContents(_queueFamilies);
	[_mtlDevice release];
}


#pragma mark -
#pragma mark MVKDevice

PFN_vkVoidFunction MVKDevice::getProcAddr(const char* pName) {
	return _physicalDevice->_mvkInstance->getProcAddr(pName);
}

VkResult MVKDevice::getDeviceQueue(uint32_t queueFamilyIndex, uint32_t queueIndex, VkQueue* pQueue) {
	*pQueue = _queuesByQueueFamilyIndex[queueFamilyIndex][queueIndex]->getVkQueue();
	return VK_SUCCESS;
}

VkResult MVKDevice::waitIdle() {
	for (auto& queues : _queuesByQueueFamilyIndex) {
		for (MVKQueue* q : queues) {
			q->waitIdle(kMVKCommandUseDeviceWaitIdle);
		}
	}
	return VK_SUCCESS;
}

const MVKDeviceConfiguration* MVKDevice::getMoltenVKConfiguration() { return &_mvkConfig; }

void MVKDevice::setMoltenVKConfiguration(const MVKDeviceConfiguration* pConfiguration) {
	if ( !pConfiguration) { return; }

	*(MVKDeviceConfiguration*)&_mvkConfig = *pConfiguration;

	// Reconfigure the queues from the updated info
	for (auto& queues : _queuesByQueueFamilyIndex) {
		for (MVKQueue* q : queues) {
			q->updateDeviceConfiguration();
		}
	}
}


#pragma mark Object lifecycle

uint32_t MVKDevice::getVulkanMemoryTypeIndex(MTLStorageMode mtlStorageMode) {
    VkMemoryPropertyFlags vkMemFlags;
    switch (mtlStorageMode) {
        case MTLStorageModePrivate:
            vkMemFlags = MVK_VK_MEMORY_TYPE_METAL_PRIVATE;
            break;
        case MTLStorageModeShared:
            vkMemFlags = MVK_VK_MEMORY_TYPE_METAL_SHARED;
            break;
#if MVK_MACOS
        case MTLStorageModeManaged:
            vkMemFlags = MVK_VK_MEMORY_TYPE_METAL_MANAGED;
            break;
#endif
        default:
            vkMemFlags = MVK_VK_MEMORY_TYPE_METAL_SHARED;
            break;
    }

    for (uint32_t mtIdx = 0; mtIdx < _pMemoryProperties->memoryTypeCount; mtIdx++) {
        if (_pMemoryProperties->memoryTypes[mtIdx].propertyFlags == vkMemFlags) { return mtIdx; }
    }
    MVKAssert(false, "Could not find memory type corresponding to VkMemoryPropertyFlags %d", vkMemFlags);
    return 0;
}

MVKBuffer* MVKDevice::createBuffer(const VkBufferCreateInfo* pCreateInfo,
								   const VkAllocationCallbacks* pAllocator) {
    return (MVKBuffer*)addResource(new MVKBuffer(this, pCreateInfo));
}

void MVKDevice::destroyBuffer(MVKBuffer* mvkBuff,
							  const VkAllocationCallbacks* pAllocator) {
	removeResource(mvkBuff);
	mvkBuff->destroy();
}

MVKBufferView* MVKDevice::createBufferView(const VkBufferViewCreateInfo* pCreateInfo,
                                           const VkAllocationCallbacks* pAllocator) {
    return new MVKBufferView(this, pCreateInfo);
}

void MVKDevice::destroyBufferView(MVKBufferView* mvkBuffView,
                                  const VkAllocationCallbacks* pAllocator) {
    mvkBuffView->destroy();
}

MVKImage* MVKDevice::createImage(const VkImageCreateInfo* pCreateInfo,
								 const VkAllocationCallbacks* pAllocator) {
	return (MVKImage*)addResource(new MVKImage(this, pCreateInfo));
}

void MVKDevice::destroyImage(MVKImage* mvkImg,
							 const VkAllocationCallbacks* pAllocator) {
	removeResource(mvkImg);
	mvkImg->destroy();
}

MVKImageView* MVKDevice::createImageView(const VkImageViewCreateInfo* pCreateInfo,
										 const VkAllocationCallbacks* pAllocator) {
	return new MVKImageView(this, pCreateInfo);
}

void MVKDevice::destroyImageView(MVKImageView* mvkImgView,
								 const VkAllocationCallbacks* pAllocator) {
	mvkImgView->destroy();
}

MVKSwapchain* MVKDevice::createSwapchain(const VkSwapchainCreateInfoKHR* pCreateInfo,
										 const VkAllocationCallbacks* pAllocator) {
	return new MVKSwapchain(this, pCreateInfo);
}

void MVKDevice::destroySwapchain(MVKSwapchain* mvkSwpChn,
								 const VkAllocationCallbacks* pAllocator) {
	mvkSwpChn->destroy();
}

MVKSwapchainImage* MVKDevice::createSwapchainImage(const VkImageCreateInfo* pCreateInfo,
												   MVKSwapchain* swapchain,
												   const VkAllocationCallbacks* pAllocator) {
	return (MVKSwapchainImage*)addResource(new MVKSwapchainImage(this, pCreateInfo, swapchain));
}

void MVKDevice::destroySwapchainImage(MVKSwapchainImage* mvkImg,
									  const VkAllocationCallbacks* pAllocator) {
	removeResource(mvkImg);
	mvkImg->destroy();
}

MVKFence* MVKDevice::createFence(const VkFenceCreateInfo* pCreateInfo,
								 const VkAllocationCallbacks* pAllocator) {
	return new MVKFence(this, pCreateInfo);
}

void MVKDevice::destroyFence(MVKFence* mvkFence,
							 const VkAllocationCallbacks* pAllocator) {
	mvkFence->destroy();
}

MVKSemaphore* MVKDevice::createSemaphore(const VkSemaphoreCreateInfo* pCreateInfo,
										 const VkAllocationCallbacks* pAllocator) {
	return new MVKSemaphore(this, pCreateInfo);
}

void MVKDevice::destroySemaphore(MVKSemaphore* mvkSem4,
								 const VkAllocationCallbacks* pAllocator) {
	mvkSem4->destroy();
}

MVKQueryPool* MVKDevice::createQueryPool(const VkQueryPoolCreateInfo* pCreateInfo,
										 const VkAllocationCallbacks* pAllocator) {
	switch (pCreateInfo->queryType) {
        case VK_QUERY_TYPE_OCCLUSION:
            return new MVKOcclusionQueryPool(this, pCreateInfo);
		case VK_QUERY_TYPE_TIMESTAMP:
			return new MVKTimestampQueryPool(this, pCreateInfo);
		case VK_QUERY_TYPE_PIPELINE_STATISTICS:
			return new MVKPipelineStatisticsQueryPool(this, pCreateInfo);
		default:
            return new MVKUnsupportedQueryPool(this, pCreateInfo);
	}
}

void MVKDevice::destroyQueryPool(MVKQueryPool* mvkQP,
								 const VkAllocationCallbacks* pAllocator) {
	mvkQP->destroy();
}

MVKShaderModule* MVKDevice::createShaderModule(const VkShaderModuleCreateInfo* pCreateInfo,
											   const VkAllocationCallbacks* pAllocator) {
	return new MVKShaderModule(this, pCreateInfo);
}

void MVKDevice::destroyShaderModule(MVKShaderModule* mvkShdrMod,
									const VkAllocationCallbacks* pAllocator) {
	mvkShdrMod->destroy();
}

MVKPipelineCache* MVKDevice::createPipelineCache(const VkPipelineCacheCreateInfo* pCreateInfo,
												 const VkAllocationCallbacks* pAllocator) {
	return new MVKPipelineCache(this, pCreateInfo);
}

void MVKDevice::destroyPipelineCache(MVKPipelineCache* mvkPLC,
									 const VkAllocationCallbacks* pAllocator) {
	mvkPLC->destroy();
}

MVKPipelineLayout* MVKDevice::createPipelineLayout(const VkPipelineLayoutCreateInfo* pCreateInfo,
												   const VkAllocationCallbacks* pAllocator) {
	return new MVKPipelineLayout(this, pCreateInfo);
}

void MVKDevice::destroyPipelineLayout(MVKPipelineLayout* mvkPLL,
									  const VkAllocationCallbacks* pAllocator) {
	mvkPLL->destroy();
}

template<typename PipelineType, typename PipelineInfoType>
VkResult MVKDevice::createPipelines(VkPipelineCache pipelineCache,
                                    uint32_t count,
                                    const PipelineInfoType* pCreateInfos,
                                    const VkAllocationCallbacks* pAllocator,
                                    VkPipeline* pPipelines) {
    VkResult rslt = VK_SUCCESS;
    MVKPipelineCache* mvkPLC = (MVKPipelineCache*)pipelineCache;

    for (uint32_t plIdx = 0; plIdx < count; plIdx++) {
        const PipelineInfoType* pCreateInfo = &pCreateInfos[plIdx];

        // See if this pipeline has a parent. This can come either directly
        // via basePipelineHandle or indirectly via basePipelineIndex.
        MVKPipeline* parentPL = VK_NULL_HANDLE;
        if ( mvkAreFlagsEnabled(pCreateInfo->flags, VK_PIPELINE_CREATE_DERIVATIVE_BIT) ) {
            VkPipeline vkParentPL = pCreateInfo->basePipelineHandle;
            int32_t parentPLIdx = pCreateInfo->basePipelineIndex;
            if ( !vkParentPL && (parentPLIdx >= 0)) { vkParentPL = pPipelines[parentPLIdx]; }
            parentPL = vkParentPL ? (MVKPipeline*)vkParentPL : VK_NULL_HANDLE;
        }

        // Create the pipeline and if creation was successful, insert the new pipeline
        // in the return array and add it to the pipeline cache (if the cache was specified).
        // If creation was unsuccessful, insert NULL into the return array, change the
        // result code of this function, and destroy the broken pipeline.
        MVKPipeline* mvkPL = new PipelineType(this, mvkPLC, parentPL, pCreateInfo);
        VkResult plRslt = mvkPL->getConfigurationResult();
        if (plRslt == VK_SUCCESS) {
            pPipelines[plIdx] = (VkPipeline)mvkPL;
        } else {
            rslt = plRslt;
            pPipelines[plIdx] = VK_NULL_HANDLE;
            mvkPL->destroy();
        }
    }

    return rslt;
}

// Create concrete implementations of the two variations of the mvkCreatePipelines() function
// that we will be using. This is required since the template definition is location in this
// implementation file instead of in the header file. This is a realistic approach if the
// universe of possible template implementation variations is small and known in advance.
template VkResult MVKDevice::createPipelines<MVKGraphicsPipeline, VkGraphicsPipelineCreateInfo>(VkPipelineCache pipelineCache,
                                                                                                uint32_t count,
                                                                                                const VkGraphicsPipelineCreateInfo* pCreateInfos,
                                                                                                const VkAllocationCallbacks* pAllocator,
                                                                                                VkPipeline* pPipelines);

template VkResult MVKDevice::createPipelines<MVKComputePipeline, VkComputePipelineCreateInfo>(VkPipelineCache pipelineCache,
                                                                                              uint32_t count,
                                                                                              const VkComputePipelineCreateInfo* pCreateInfos,
                                                                                              const VkAllocationCallbacks* pAllocator,
                                                                                              VkPipeline* pPipelines);

void MVKDevice::destroyPipeline(MVKPipeline* mvkPL,
                                const VkAllocationCallbacks* pAllocator) {
    mvkPL->destroy();
}

MVKSampler* MVKDevice::createSampler(const VkSamplerCreateInfo* pCreateInfo,
									 const VkAllocationCallbacks* pAllocator) {
	return new MVKSampler(this, pCreateInfo);
}

void MVKDevice::destroySampler(MVKSampler* mvkSamp,
							   const VkAllocationCallbacks* pAllocator) {
	mvkSamp->destroy();
}

MVKDescriptorSetLayout* MVKDevice::createDescriptorSetLayout(const VkDescriptorSetLayoutCreateInfo* pCreateInfo,
															 const VkAllocationCallbacks* pAllocator) {
	return new MVKDescriptorSetLayout(this, pCreateInfo);
}

void MVKDevice::destroyDescriptorSetLayout(MVKDescriptorSetLayout* mvkDSL,
										   const VkAllocationCallbacks* pAllocator) {
	mvkDSL->destroy();
}

MVKDescriptorPool* MVKDevice::createDescriptorPool(const VkDescriptorPoolCreateInfo* pCreateInfo,
												   const VkAllocationCallbacks* pAllocator) {
	return new MVKDescriptorPool(this, pCreateInfo);
}

void MVKDevice::destroyDescriptorPool(MVKDescriptorPool* mvkDP,
									  const VkAllocationCallbacks* pAllocator) {
	mvkDP->destroy();
}

MVKFramebuffer* MVKDevice::createFramebuffer(const VkFramebufferCreateInfo* pCreateInfo,
											 const VkAllocationCallbacks* pAllocator) {
	return new MVKFramebuffer(this, pCreateInfo);
}

void MVKDevice::destroyFramebuffer(MVKFramebuffer* mvkFB,
								   const VkAllocationCallbacks* pAllocator) {
	mvkFB->destroy();
}

MVKRenderPass* MVKDevice::createRenderPass(const VkRenderPassCreateInfo* pCreateInfo,
										   const VkAllocationCallbacks* pAllocator) {
	return new MVKRenderPass(this, pCreateInfo);
}

void MVKDevice::destroyRenderPass(MVKRenderPass* mvkRP,
								  const VkAllocationCallbacks* pAllocator) {
	mvkRP->destroy();
}

MVKCommandPool* MVKDevice::createCommandPool(const VkCommandPoolCreateInfo* pCreateInfo,
											const VkAllocationCallbacks* pAllocator) {
	return new MVKCommandPool(this, pCreateInfo);
}

void MVKDevice::destroyCommandPool(MVKCommandPool* mvkCmdPool,
								   const VkAllocationCallbacks* pAllocator) {
	mvkCmdPool->destroy();
}

MVKDeviceMemory* MVKDevice::allocateMemory(const VkMemoryAllocateInfo* pAllocateInfo,
										   const VkAllocationCallbacks* pAllocator) {
	return new MVKDeviceMemory(this, pAllocateInfo, pAllocator);
}

void MVKDevice::freeMemory(MVKDeviceMemory* mvkDevMem,
						   const VkAllocationCallbacks* pAllocator) {
	mvkDevMem->destroy();
}

/** Adds the specified resource for tracking, and returns the added resource. */
MVKResource* MVKDevice::addResource(MVKResource* rez) {
	lock_guard<mutex> lock(_rezLock);
	_resources.push_back(rez);
	return rez;
}

/** Removes the specified resource for tracking and returns the removed resource. */
MVKResource* MVKDevice::removeResource(MVKResource* rez) {
	lock_guard<mutex> lock(_rezLock);
	mvkRemoveFirstOccurance(_resources, rez);
	return rez;
}

void MVKDevice::applyMemoryBarrier(VkPipelineStageFlags srcStageMask,
								   VkPipelineStageFlags dstStageMask,
								   VkMemoryBarrier* pMemoryBarrier,
                                   MVKCommandEncoder* cmdEncoder,
                                   MVKCommandUse cmdUse) {
	lock_guard<mutex> lock(_rezLock);
    for (auto& rez : _resources) {
		rez->applyMemoryBarrier(srcStageMask, dstStageMask, pMemoryBarrier, cmdEncoder, cmdUse);
	}
}

uint64_t MVKDevice::getPerformanceTimestampImpl() { return mvkGetTimestamp(); }

void MVKDevice::addActivityPerformanceImpl(MVKPerformanceTracker& shaderCompilationEvent,
										   uint64_t startTime, uint64_t endTime) {
    lock_guard<mutex> lock(_perfLock);

	double currInterval = mvkGetElapsedMilliseconds(startTime, endTime);
    shaderCompilationEvent.minimumDuration = min(currInterval, shaderCompilationEvent.minimumDuration);
    shaderCompilationEvent.maximumDuration = max(currInterval, shaderCompilationEvent.maximumDuration);
    double totalInterval = (shaderCompilationEvent.averageDuration * shaderCompilationEvent.count++) + currInterval;
    shaderCompilationEvent.averageDuration = totalInterval / shaderCompilationEvent.count;

	MVKLogDebug("Performance to %s curr: %.3f ms, avg: %.3f ms, min: %.3f ms, max: %.3f ms, count: %d",
				getActivityPerformanceDescription(shaderCompilationEvent),
				currInterval,
				shaderCompilationEvent.averageDuration,
				shaderCompilationEvent.minimumDuration,
				shaderCompilationEvent.maximumDuration,
				shaderCompilationEvent.count);
}

const char* MVKDevice::getActivityPerformanceDescription(MVKPerformanceTracker& shaderCompilationEvent) {
	if (&shaderCompilationEvent == &_performanceStatistics.shaderCompilation.hashShaderCode) { return "hash shader SPIR-V code"; }
    if (&shaderCompilationEvent == &_performanceStatistics.shaderCompilation.spirvToMSL) { return "convert SPIR-V to MSL source code"; }
    if (&shaderCompilationEvent == &_performanceStatistics.shaderCompilation.mslCompile) { return "compile MSL source code into a MTLLibrary"; }
    if (&shaderCompilationEvent == &_performanceStatistics.shaderCompilation.mslLoad) { return "load pre-compiled MSL code into a MTLLibrary"; }
	if (&shaderCompilationEvent == &_performanceStatistics.shaderCompilation.shaderLibraryFromCache) { return "retrieve shader library from the cache"; }
    if (&shaderCompilationEvent == &_performanceStatistics.shaderCompilation.functionRetrieval) { return "retrieve a MTLFunction from a MTLLibrary"; }
    if (&shaderCompilationEvent == &_performanceStatistics.shaderCompilation.functionSpecialization) { return "specialize a retrieved MTLFunction"; }
    if (&shaderCompilationEvent == &_performanceStatistics.shaderCompilation.pipelineCompile) { return "compile MTLFunctions into a pipeline"; }
	if (&shaderCompilationEvent == &_performanceStatistics.pipelineCache.sizePipelineCache) { return "calculate cache size required to write MSL to pipeline cache"; }
	if (&shaderCompilationEvent == &_performanceStatistics.pipelineCache.writePipelineCache) { return "write MSL to pipeline cache"; }
	if (&shaderCompilationEvent == &_performanceStatistics.pipelineCache.readPipelineCache) { return "read MSL from pipeline cache"; }
	if (&shaderCompilationEvent == &_performanceStatistics.queue.mtlQueueAccess) { return "access MTLCommandQueue"; }
    return "Unknown shader compile event";
}

void MVKDevice::getPerformanceStatistics(MVKPerformanceStatistics* pPerf) {
    lock_guard<mutex> lock(_perfLock);

    if (pPerf) { *pPerf = _performanceStatistics; }
}


#pragma mark Metal

uint32_t MVKDevice::getMetalBufferIndexForVertexAttributeBinding(uint32_t binding) {
	return ((_pMetalFeatures->maxPerStageBufferCount - 1) - binding);
}

MTLPixelFormat MVKDevice::mtlPixelFormatFromVkFormat(VkFormat vkFormat) {
	MTLPixelFormat mtlPixFmt = mvkMTLPixelFormatFromVkFormat(vkFormat);
#if MVK_MACOS
	if (mtlPixFmt == MTLPixelFormatDepth24Unorm_Stencil8 &&
		!getMTLDevice().isDepth24Stencil8PixelFormatSupported) {
		return MTLPixelFormatDepth32Float_Stencil8;
	}
#endif
	return mtlPixFmt;
}

id<MTLBuffer> MVKDevice::getGlobalVisibilityResultMTLBuffer() {
    lock_guard<mutex> lock(_vizLock);
    return _globalVisibilityResultMTLBuffer;
}

uint32_t MVKDevice::expandVisibilityResultMTLBuffer(uint32_t queryCount) {
    lock_guard<mutex> lock(_vizLock);

    // Ensure we don't overflow the maximum number of queries
    _globalVisibilityQueryCount += queryCount;
    VkDeviceSize reqBuffLen = (VkDeviceSize)_globalVisibilityQueryCount * kMVKQuerySlotSizeInBytes;
    VkDeviceSize maxBuffLen = _pMetalFeatures->maxQueryBufferSize;
    VkDeviceSize newBuffLen = min(reqBuffLen, maxBuffLen);
    _globalVisibilityQueryCount = uint32_t(newBuffLen / kMVKQuerySlotSizeInBytes);

    if (reqBuffLen > maxBuffLen) {
        mvkNotifyErrorWithText(VK_ERROR_OUT_OF_DEVICE_MEMORY, "vkCreateQueryPool(): A maximum of %d total queries are available on this device in its current configuration. See the API notes for the MVKDeviceConfiguration.supportLargeQueryPools configuration parameter for more info.", _globalVisibilityQueryCount);
    }

    NSUInteger mtlBuffLen = mvkAlignByteOffset(newBuffLen, _pMetalFeatures->mtlBufferAlignment);
    MTLResourceOptions mtlBuffOpts = MTLResourceStorageModeShared | MTLResourceCPUCacheModeDefaultCache;
    [_globalVisibilityResultMTLBuffer release];
    _globalVisibilityResultMTLBuffer = [getMTLDevice() newBufferWithLength: mtlBuffLen options: mtlBuffOpts];     // retained

    return _globalVisibilityQueryCount - queryCount;     // Might be lower than requested if an overflow occurred
}


#pragma mark Construction

MVKDevice::MVKDevice(MVKPhysicalDevice* physicalDevice, const VkDeviceCreateInfo* pCreateInfo) : _mvkConfig() {

	initPerformanceTracking();

	_physicalDevice = physicalDevice;
	_pFeatures = &_physicalDevice->_features.features;
	_pMetalFeatures = &_physicalDevice->_metalFeatures;
	_pProperties = &_physicalDevice->_properties.properties;
	_pMemoryProperties = &_physicalDevice->_memoryProperties;

    // Init const config. Use a pointer to bypass the const qualifier.
    MVKDeviceConfiguration* pCfg = (MVKDeviceConfiguration*)&_mvkConfig;
    pCfg->debugMode = MVK_DEBUG;
	pCfg->synchronousQueueSubmits = false;
    pCfg->supportLargeQueryPools = true;
    pCfg->shaderConversionFlipVertexY = true;
	pCfg->presentWithCommandBuffer = MVK_PRESENT_WITH_COMMAND_BUFFER_BOOL;
	pCfg->swapchainMagFilterUseNearest = true;
    pCfg->displayWatermark = MVK_DISPLAY_WATERMARK_BOOL;
    pCfg->performanceTracking = MVK_DEBUG;
    pCfg->performanceLoggingFrameCount = MVK_DEBUG ? 300 : 0;
	pCfg->metalCompileTimeout = numeric_limits<int64_t>::max();

    _globalVisibilityResultMTLBuffer = nil;
    _globalVisibilityQueryCount = 0;

    // Verify the requested extension names. Should be same as those requested from instance.
    setConfigurationResult(_physicalDevice->_mvkInstance->verifyExtensions(pCreateInfo->enabledExtensionCount,
                                                                           pCreateInfo->ppEnabledExtensionNames));

    _commandResourceFactory = new MVKCommandResourceFactory(this);

	// Create the queues
	uint32_t qrCnt = pCreateInfo->queueCreateInfoCount;
	for (uint32_t qrIdx = 0; qrIdx < qrCnt; qrIdx++) {
		const VkDeviceQueueCreateInfo* pQFInfo = &pCreateInfo->pQueueCreateInfos[qrIdx];
		uint32_t qfIdx = pQFInfo->queueFamilyIndex;
		MVKQueueFamily* qFam = _physicalDevice->_queueFamilies[qfIdx];
		_queuesByQueueFamilyIndex.resize(qfIdx + 1);	// Ensure an entry for this queue family exists
		auto& queues = _queuesByQueueFamilyIndex[qfIdx];
		for (uint32_t qIdx = 0; qIdx < pQFInfo->queueCount; qIdx++) {
			queues.push_back(new MVKQueue(this, qFam, qIdx, pQFInfo->pQueuePriorities[qIdx]));
		}
	}

	MVKLogInfo("Created VkDevice to run on GPU %s", _pProperties->deviceName);
}

void MVKDevice::initPerformanceTracking() {
    MVKPerformanceTracker initPerf;
    initPerf.count = 0;
    initPerf.averageDuration = 0.0;
    initPerf.minimumDuration = numeric_limits<double>::max();
    initPerf.maximumDuration = 0.0;

	_performanceStatistics.shaderCompilation.hashShaderCode = initPerf;
    _performanceStatistics.shaderCompilation.spirvToMSL = initPerf;
    _performanceStatistics.shaderCompilation.mslCompile = initPerf;
    _performanceStatistics.shaderCompilation.mslLoad = initPerf;
	_performanceStatistics.shaderCompilation.shaderLibraryFromCache = initPerf;
    _performanceStatistics.shaderCompilation.functionRetrieval = initPerf;
    _performanceStatistics.shaderCompilation.functionSpecialization = initPerf;
    _performanceStatistics.shaderCompilation.pipelineCompile = initPerf;
	_performanceStatistics.pipelineCache.sizePipelineCache = initPerf;
	_performanceStatistics.pipelineCache.writePipelineCache = initPerf;
	_performanceStatistics.pipelineCache.readPipelineCache = initPerf;
	_performanceStatistics.queue.mtlQueueAccess = initPerf;
}

MVKDevice::~MVKDevice() {
	for (auto& queues : _queuesByQueueFamilyIndex) {
		mvkDestroyContainerContents(queues);
	}
    [_globalVisibilityResultMTLBuffer release];
	_commandResourceFactory->destroy();
}


