#include <jni.h>
#include <android/hardware_buffer_jni.h>
#include <android/native_window_jni.h>
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <link.h>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include <array>
#include <algorithm>
#include <cstring>
#include <time.h>
#include "shaders.h"

namespace {
void check(VkResult r, const char* operation) { if (r != VK_SUCCESS) throw std::runtime_error(std::string(operation)+": "+std::to_string(r)); }
void fail(JNIEnv* env, const std::exception& e) { env->ThrowNew(env->FindClass("java/lang/IllegalStateException"),e.what()); }
struct StaleDepth : std::runtime_error { StaleDepth():std::runtime_error("staleDepth: Retained depth observation exceeded 250 milliseconds.") {} };
void requireDepthFresh(uint64_t deadline) {
 if(!deadline) return;
 timespec now{}; if(clock_gettime(CLOCK_BOOTTIME,&now)!=0) throw std::runtime_error("Depth clock unavailable.");
 if(static_cast<uint64_t>(now.tv_sec)*1'000'000'000+now.tv_nsec>deadline) throw StaleDepth();
}
struct Search { uint64_t token; void* library=nullptr; };
int findRuntime(dl_phdr_info* info,size_t,void* opaque) {
 auto& s=*static_cast<Search*>(opaque); if(!info->dlpi_name || !*info->dlpi_name) return 0;
 auto lib=dlopen(info->dlpi_name,RTLD_NOW|RTLD_NOLOAD); if(!lib) return 0;
 auto token=reinterpret_cast<uint64_t(*)()>(dlsym(lib,"fg2_runtime_token"));
 if(token && token()==s.token) { s.library=lib; return 1; } dlclose(lib); return 0;
}
struct Runtime {
 void* library=nullptr; uint64_t renderer=0;
 uint64_t (*create)(); uint32_t (*destroy)(uint64_t); size_t (*error)(uint8_t*,size_t);
 uint32_t (*context)(uint64_t,uint64_t*);
 uint32_t (*render)(uint64_t,const uint8_t*,size_t,uint64_t,uint64_t,uint64_t,uint32_t,uint32_t);
 using Command=uint32_t(*)(uint64_t,const uint8_t*,size_t,uint8_t*,size_t,size_t*);
 Command commands[3];
 template<class T> T load(const char* name) { auto p=dlsym(library,name); if(!p) throw std::runtime_error(std::string("Missing runtime symbol: ")+name); return reinterpret_cast<T>(p); }
 std::string lastError() { auto n=error(nullptr,0); std::string text(n,'\0'); error(reinterpret_cast<uint8_t*>(text.data()),n); return text; }
 void require(uint32_t status) { if(status!=1) throw std::runtime_error(lastError()); }
 explicit Runtime(uint64_t token) {
  Search search{token}; dl_iterate_phdr(findRuntime,&search); library=search.library;
  if(!library) throw std::runtime_error("Dart runtime identity was not found.");
  try {
   create=load<decltype(create)>("fg_create"); destroy=load<decltype(destroy)>("fg_destroy"); error=load<decltype(error)>("fg_last_error");
   context=load<decltype(context)>("fg_android_vulkan_context"); render=load<decltype(render)>("fg_android_render_image");
   const char* names[]={"fg2_resource_command","fg2_shader_command","fg2_graph_command"}; for(int i=0;i<3;i++) commands[i]=load<Command>(names[i]);
   renderer=create(); if(!renderer) throw std::runtime_error(lastError());
  } catch(...) { if(renderer) destroy(renderer); dlclose(library); throw; }
 }
 ~Runtime() { if(renderer) destroy(renderer); if(library) dlclose(library); }
};
struct Image {
 VkDevice device; VkImage image=VK_NULL_HANDLE; VkImageView view=VK_NULL_HANDLE; VkDeviceMemory memory=VK_NULL_HANDLE;
 explicit Image(VkDevice d):device(d) {}
 ~Image() { if(view) vkDestroyImageView(device,view,nullptr); if(image) vkDestroyImage(device,image,nullptr); if(memory) vkFreeMemory(device,memory,nullptr); }
};
struct Buffer {
 VkDevice device; VkBuffer buffer=VK_NULL_HANDLE; VkDeviceMemory memory=VK_NULL_HANDLE;
 explicit Buffer(VkDevice d):device(d) {}
 ~Buffer() { if(buffer) vkDestroyBuffer(device,buffer,nullptr); if(memory) vkFreeMemory(device,memory,nullptr); }
};
struct Camera {
 VkDevice device; AHardwareBuffer* buffer=nullptr; Image image;
 VkSamplerYcbcrConversion conversion=VK_NULL_HANDLE; VkSampler sampler=VK_NULL_HANDLE;
 explicit Camera(VkDevice d):device(d),image(d) {}
 ~Camera() { if(sampler) vkDestroySampler(device,sampler,nullptr); if(image.view) { vkDestroyImageView(device,image.view,nullptr); image.view=VK_NULL_HANDLE; } if(conversion) reinterpret_cast<PFN_vkDestroySamplerYcbcrConversion>(vkGetDeviceProcAddr(device,"vkDestroySamplerYcbcrConversion"))(device,conversion,nullptr); if(buffer) AHardwareBuffer_release(buffer); }
};
struct Draw {
 VkDevice device; VkPipeline pipeline=VK_NULL_HANDLE; VkPipelineLayout layout=VK_NULL_HANDLE;
 VkDescriptorSetLayout descriptorLayout=VK_NULL_HANDLE; VkDescriptorPool pool=VK_NULL_HANDLE; VkDescriptorSet descriptors=VK_NULL_HANDLE;
 VkFramebuffer framebuffer=VK_NULL_HANDLE; VkRenderPass pass=VK_NULL_HANDLE;
 VkShaderModule vert=VK_NULL_HANDLE,frag=VK_NULL_HANDLE; VkSampler sceneSampler=VK_NULL_HANDLE;
 explicit Draw(VkDevice d):device(d) {}
 ~Draw() { if(framebuffer) vkDestroyFramebuffer(device,framebuffer,nullptr); if(pipeline) vkDestroyPipeline(device,pipeline,nullptr); if(layout) vkDestroyPipelineLayout(device,layout,nullptr); if(pool) vkDestroyDescriptorPool(device,pool,nullptr); if(descriptorLayout) vkDestroyDescriptorSetLayout(device,descriptorLayout,nullptr); if(pass) vkDestroyRenderPass(device,pass,nullptr); if(vert) vkDestroyShaderModule(device,vert,nullptr); if(frag) vkDestroyShaderModule(device,frag,nullptr); if(sceneSampler) vkDestroySampler(device,sceneSampler,nullptr); }
};
struct FrameResources {
 Camera camera; Image scene,depth; Buffer source,projected; Draw depthDraw,draw;
 explicit FrameResources(VkDevice d):camera(d),scene(d),depth(d),source(d),projected(d),depthDraw(d),draw(d) {}
};
struct Presenter {
 Runtime runtime; VkInstance instance=VK_NULL_HANDLE; VkPhysicalDevice physical=VK_NULL_HANDLE; VkDevice device=VK_NULL_HANDLE; VkQueue queue=VK_NULL_HANDLE; uint32_t family=0;
 ANativeWindow* window=nullptr; VkSurfaceKHR surface=VK_NULL_HANDLE; VkSwapchainKHR swapchain=VK_NULL_HANDLE;
 VkFormat format=VK_FORMAT_UNDEFINED; uint32_t width=0,height=0,index=0;
 VkCommandPool commandPool=VK_NULL_HANDLE; VkCommandBuffer command=VK_NULL_HANDLE;
 VkSemaphore acquired=VK_NULL_HANDLE; VkFence fence=VK_NULL_HANDLE,acquireFence=VK_NULL_HANDLE;
 std::vector<VkSemaphore> finished; std::vector<VkFence> presentFences; std::vector<bool> presenting;
 bool presentationUnknown=false,acquisitionPending=false;
 std::vector<VkImage> images; std::vector<VkImageView> views;
 bool pending=false,failed=false;
 std::unique_ptr<FrameResources> failedResources;
 explicit Presenter(uint64_t token):runtime(token) {
  uint64_t values[6]={}; runtime.require(runtime.context(runtime.renderer,values));
  instance=reinterpret_cast<VkInstance>(values[0]); physical=reinterpret_cast<VkPhysicalDevice>(values[1]); device=reinterpret_cast<VkDevice>(values[2]); queue=reinterpret_cast<VkQueue>(values[3]); family=values[4];
  try {
   VkCommandPoolCreateInfo pool{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; pool.queueFamilyIndex=family; pool.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT; check(vkCreateCommandPool(device,&pool,nullptr,&commandPool),"command pool");
   VkCommandBufferAllocateInfo alloc{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO}; alloc.commandPool=commandPool; alloc.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY; alloc.commandBufferCount=1; check(vkAllocateCommandBuffers(device,&alloc,&command),"command buffer");
   VkSemaphoreCreateInfo sem{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO}; check(vkCreateSemaphore(device,&sem,nullptr,&acquired),"acquire semaphore");
   VkFenceCreateInfo fi{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; check(vkCreateFence(device,&fi,nullptr,&fence),"completion fence"); check(vkCreateFence(device,&fi,nullptr,&acquireFence),"acquisition fence");
  } catch(...) { cleanup(); throw; }
 }
 ~Presenter() { cleanup(); }
 bool gpuRetired() {
  auto result=vkDeviceWaitIdle(device);
  return result==VK_SUCCESS || result==VK_ERROR_DEVICE_LOST;
 }
 void retire() {
  auto idle=vkDeviceWaitIdle(device);
  if(idle==VK_ERROR_DEVICE_LOST) return;
  check(idle,"Vulkan retirement pending; retry disposal");
  if(presentationUnknown) throw std::runtime_error("Presentation retirement is unknown; surface owner retained.");
  if(acquisitionPending) {
   auto result=vkWaitForFences(device,1,&acquireFence,VK_TRUE,1'000'000'000);
   if(result==VK_ERROR_DEVICE_LOST) return;
   check(result,"Acquisition retirement pending; retry disposal");
  }
  // Device idle does not prove that the presentation engine consumed its waits.
  for(size_t i=0;i<presentFences.size();i++) if(presenting[i]) {
   auto result=vkWaitForFences(device,1,&presentFences[i],VK_TRUE,1'000'000'000);
   if(result==VK_ERROR_DEVICE_LOST) return;
   check(result,"Presentation retirement pending; retry disposal");
  }
 }
 void releaseSurface() {
  failedResources.reset();
  for(auto view:views) vkDestroyImageView(device,view,nullptr); views.clear(); images.clear();
  for(auto sem:finished) vkDestroySemaphore(device,sem,nullptr); finished.clear();
  for(auto f:presentFences) vkDestroyFence(device,f,nullptr); presentFences.clear(); presenting.clear();
  if(swapchain) vkDestroySwapchainKHR(device,swapchain,nullptr); swapchain=VK_NULL_HANDLE;
  if(surface) vkDestroySurfaceKHR(instance,surface,nullptr); surface=VK_NULL_HANDLE;
  if(window) ANativeWindow_release(window); window=nullptr; pending=false; acquisitionPending=false;
 }
 // Called only before any submission (constructor failure) or after retire().
 void cleanup() {
  if(!device) return; releaseSurface();
  if(fence) vkDestroyFence(device,fence,nullptr); if(acquireFence) vkDestroyFence(device,acquireFence,nullptr); if(acquired) vkDestroySemaphore(device,acquired,nullptr); if(commandPool) vkDestroyCommandPool(device,commandPool,nullptr); device=VK_NULL_HANDLE;
 }
 void detach() { retire(); releaseSurface(); }
 uint32_t memoryType(uint32_t bits,VkMemoryPropertyFlags flags=0) {
  VkPhysicalDeviceMemoryProperties properties; vkGetPhysicalDeviceMemoryProperties(physical,&properties);
  for(uint32_t i=0;i<properties.memoryTypeCount;i++) if((bits&(1u<<i)) && (properties.memoryTypes[i].propertyFlags&flags)==flags) return i;
  throw std::runtime_error("No compatible Vulkan memory type.");
 }
 void attach(ANativeWindow* w,uint32_t requestedWidth,uint32_t requestedHeight) {
  try { detach(); } catch(...) { if(w) ANativeWindow_release(w); throw; } window=w;
  if(!w) return;
  if(requestedWidth==0 || requestedHeight==0 || requestedWidth>4096 || requestedHeight>4096) throw std::runtime_error("Invalid camera surface dimensions.");
  VkAndroidSurfaceCreateInfoKHR info{VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR}; info.window=w; check(vkCreateAndroidSurfaceKHR(instance,&info,nullptr,&surface),"Android surface");
  VkBool32 supported=VK_FALSE; check(vkGetPhysicalDeviceSurfaceSupportKHR(physical,family,surface,&supported),"surface support"); if(!supported) throw std::runtime_error("Vulkan queue cannot present this surface.");
  VkSurfaceCapabilitiesKHR caps; check(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical,surface,&caps),"surface capabilities");
  uint32_t count=0; check(vkGetPhysicalDeviceSurfaceFormatsKHR(physical,surface,&count,nullptr),"surface formats"); std::vector<VkSurfaceFormatKHR> formats(count); check(vkGetPhysicalDeviceSurfaceFormatsKHR(physical,surface,&count,formats.data()),"surface formats");
  auto chosen=std::find_if(formats.begin(),formats.end(),[](auto f){return (f.format==VK_FORMAT_R8G8B8A8_SRGB || f.format==VK_FORMAT_B8G8R8A8_SRGB) && f.colorSpace==VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;});
  if(chosen==formats.end()) throw std::runtime_error("Vulkan camera surface has no sRGB format."); format=chosen->format;
  width=caps.currentExtent.width==UINT32_MAX?requestedWidth:caps.currentExtent.width; height=caps.currentExtent.height==UINT32_MAX?requestedHeight:caps.currentExtent.height;
  if(width!=requestedWidth || height!=requestedHeight) throw std::runtime_error("Camera surface dimensions changed.");
  VkSwapchainCreateInfoKHR swap{VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR}; swap.surface=surface; swap.minImageCount=std::max(2u,caps.minImageCount); if(caps.maxImageCount && swap.minImageCount>caps.maxImageCount) swap.minImageCount=caps.maxImageCount;
  swap.imageFormat=format; swap.imageColorSpace=chosen->colorSpace; swap.imageExtent={width,height}; swap.imageArrayLayers=1; swap.imageUsage=VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT; swap.imageSharingMode=VK_SHARING_MODE_EXCLUSIVE; swap.preTransform=caps.currentTransform;
  swap.compositeAlpha=VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR; if(!(caps.supportedCompositeAlpha&swap.compositeAlpha)) swap.compositeAlpha=VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
  swap.presentMode=VK_PRESENT_MODE_FIFO_KHR; swap.clipped=VK_TRUE; check(vkCreateSwapchainKHR(device,&swap,nullptr,&swapchain),"swapchain");
  check(vkGetSwapchainImagesKHR(device,swapchain,&count,nullptr),"swapchain images"); images.resize(count); check(vkGetSwapchainImagesKHR(device,swapchain,&count,images.data()),"swapchain images");
  for(auto image:images) {
   views.push_back(view(image,format));
   VkSemaphoreCreateInfo sem{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO}; VkSemaphore ready;
   check(vkCreateSemaphore(device,&sem,nullptr,&ready),"image presentation semaphore"); finished.push_back(ready);
   VkFenceCreateInfo info{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; VkFence done;
   check(vkCreateFence(device,&info,nullptr,&done),"image presentation fence"); presentFences.push_back(done); presenting.push_back(false);
  }
 }
 VkImageView view(VkImage image,VkFormat f,void* next=nullptr) {
  VkImageViewCreateInfo ci{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO}; ci.pNext=next; ci.image=image; ci.viewType=VK_IMAGE_VIEW_TYPE_2D; ci.format=f; ci.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}; VkImageView out; check(vkCreateImageView(device,&ci,nullptr,&out),"image view"); return out;
 }
 void makeScene(Image& out) {
  VkImageCreateInfo ci{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO}; ci.imageType=VK_IMAGE_TYPE_2D; ci.format=VK_FORMAT_R8G8B8A8_SRGB; ci.extent={width,height,1}; ci.mipLevels=1; ci.arrayLayers=1; ci.samples=VK_SAMPLE_COUNT_1_BIT; ci.tiling=VK_IMAGE_TILING_OPTIMAL; ci.usage=VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_SAMPLED_BIT; ci.sharingMode=VK_SHARING_MODE_EXCLUSIVE;
  check(vkCreateImage(device,&ci,nullptr,&out.image),"scene image"); VkMemoryRequirements requirements; vkGetImageMemoryRequirements(device,out.image,&requirements);
  VkMemoryAllocateInfo alloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; alloc.allocationSize=requirements.size; alloc.memoryTypeIndex=memoryType(requirements.memoryTypeBits); check(vkAllocateMemory(device,&alloc,nullptr,&out.memory),"scene memory"); check(vkBindImageMemory(device,out.image,out.memory,0),"scene bind"); out.view=view(out.image,ci.format);
 }
 void importCamera(Camera& camera,AHardwareBuffer* buffer) {
  AHardwareBuffer_acquire(buffer); camera.buffer=buffer; AHardwareBuffer_Desc desc; AHardwareBuffer_describe(buffer,&desc);
  auto getProperties=reinterpret_cast<PFN_vkGetAndroidHardwareBufferPropertiesANDROID>(vkGetDeviceProcAddr(device,"vkGetAndroidHardwareBufferPropertiesANDROID"));
  if(!getProperties) throw std::runtime_error("Android hardware-buffer import function is unavailable.");
  VkAndroidHardwareBufferFormatPropertiesANDROID fp{VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_FORMAT_PROPERTIES_ANDROID}; VkAndroidHardwareBufferPropertiesANDROID properties{VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID}; properties.pNext=&fp;
  check(getProperties(device,buffer,&properties),"hardware buffer properties");
  if(!fp.externalFormat || !(fp.formatFeatures&VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT)) throw std::runtime_error("Camera hardware buffer cannot be sampled.");
  VkExternalFormatANDROID external{VK_STRUCTURE_TYPE_EXTERNAL_FORMAT_ANDROID}; external.externalFormat=fp.externalFormat;
  VkExternalMemoryImageCreateInfo ext{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO}; ext.handleTypes=VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID; ext.pNext=&external;
  VkImageCreateInfo ci{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO}; ci.pNext=&ext; ci.imageType=VK_IMAGE_TYPE_2D; ci.format=VK_FORMAT_UNDEFINED; ci.extent={desc.width,desc.height,1}; ci.mipLevels=1; ci.arrayLayers=1; ci.samples=VK_SAMPLE_COUNT_1_BIT; ci.tiling=VK_IMAGE_TILING_OPTIMAL; ci.usage=VK_IMAGE_USAGE_SAMPLED_BIT; ci.sharingMode=VK_SHARING_MODE_EXCLUSIVE;
  check(vkCreateImage(device,&ci,nullptr,&camera.image.image),"camera import image");
  VkImportAndroidHardwareBufferInfoANDROID imported{VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID}; imported.buffer=buffer;
  VkMemoryDedicatedAllocateInfo dedicated{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO}; dedicated.image=camera.image.image; dedicated.pNext=&imported;
  VkMemoryAllocateInfo alloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; alloc.pNext=&dedicated; alloc.allocationSize=properties.allocationSize; alloc.memoryTypeIndex=memoryType(properties.memoryTypeBits);
  check(vkAllocateMemory(device,&alloc,nullptr,&camera.image.memory),"camera imported memory"); check(vkBindImageMemory(device,camera.image.image,camera.image.memory,0),"camera memory bind");
  VkSamplerYcbcrConversionCreateInfo conversion{VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_CREATE_INFO}; conversion.pNext=&external; conversion.format=VK_FORMAT_UNDEFINED; conversion.ycbcrModel=fp.suggestedYcbcrModel; conversion.ycbcrRange=fp.suggestedYcbcrRange; conversion.components=fp.samplerYcbcrConversionComponents; conversion.xChromaOffset=fp.suggestedXChromaOffset; conversion.yChromaOffset=fp.suggestedYChromaOffset; conversion.chromaFilter=VK_FILTER_NEAREST;
  auto convert = reinterpret_cast<PFN_vkCreateSamplerYcbcrConversion>(vkGetDeviceProcAddr(device,"vkCreateSamplerYcbcrConversion"));
  if(!convert || !vkGetDeviceProcAddr(device,"vkDestroySamplerYcbcrConversion")) throw std::runtime_error("Vulkan YCbCr conversion functions are unavailable.");
  check(convert(device,&conversion,nullptr,&camera.conversion),"camera YCbCr conversion");
  VkSamplerYcbcrConversionInfo converted{VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO}; converted.conversion=camera.conversion;
  camera.image.view=view(camera.image.image,VK_FORMAT_UNDEFINED,&converted);
  VkSamplerCreateInfo sampler{VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO}; sampler.pNext=&converted; sampler.magFilter=VK_FILTER_NEAREST; sampler.minFilter=VK_FILTER_NEAREST; sampler.mipmapMode=VK_SAMPLER_MIPMAP_MODE_NEAREST; sampler.addressModeU=sampler.addressModeV=sampler.addressModeW=VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE; sampler.maxLod=0;
  check(vkCreateSampler(device,&sampler,nullptr,&camera.sampler),"camera sampler");
 }
 void pipeline(Draw& d,Camera& camera,Image& scene) {
  VkAttachmentDescription attachment{}; attachment.format=format; attachment.samples=VK_SAMPLE_COUNT_1_BIT; attachment.loadOp=VK_ATTACHMENT_LOAD_OP_DONT_CARE; attachment.storeOp=VK_ATTACHMENT_STORE_OP_STORE; attachment.initialLayout=VK_IMAGE_LAYOUT_UNDEFINED; attachment.finalLayout=VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
  VkAttachmentReference color{0,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL}; VkSubpassDescription subpass{}; subpass.pipelineBindPoint=VK_PIPELINE_BIND_POINT_GRAPHICS; subpass.colorAttachmentCount=1; subpass.pColorAttachments=&color;
  VkRenderPassCreateInfo pass{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO}; pass.attachmentCount=1; pass.pAttachments=&attachment; pass.subpassCount=1; pass.pSubpasses=&subpass; check(vkCreateRenderPass(device,&pass,nullptr,&d.pass),"camera render pass");
  VkFramebufferCreateInfo fb{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO}; fb.renderPass=d.pass; fb.attachmentCount=1; fb.pAttachments=&views[index]; fb.width=width; fb.height=height; fb.layers=1; check(vkCreateFramebuffer(device,&fb,nullptr,&d.framebuffer),"camera framebuffer");
  VkSamplerCreateInfo sampler{VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO}; sampler.magFilter=VK_FILTER_LINEAR; sampler.minFilter=VK_FILTER_LINEAR; sampler.mipmapMode=VK_SAMPLER_MIPMAP_MODE_NEAREST; sampler.addressModeU=sampler.addressModeV=sampler.addressModeW=VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE; check(vkCreateSampler(device,&sampler,nullptr,&d.sceneSampler),"scene sampler");
  VkDescriptorSetLayoutBinding bindings[2]{}; for(uint32_t i=0;i<2;i++) { bindings[i].binding=i; bindings[i].descriptorType=VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER; bindings[i].descriptorCount=1; bindings[i].stageFlags=VK_SHADER_STAGE_FRAGMENT_BIT; } bindings[0].pImmutableSamplers=&camera.sampler;
  VkDescriptorSetLayoutCreateInfo layout{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO}; layout.bindingCount=2; layout.pBindings=bindings; check(vkCreateDescriptorSetLayout(device,&layout,nullptr,&d.descriptorLayout),"camera descriptor layout");
  VkDescriptorPoolSize poolSize{VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,8}; VkDescriptorPoolCreateInfo pool{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO}; pool.maxSets=1; pool.poolSizeCount=1; pool.pPoolSizes=&poolSize; check(vkCreateDescriptorPool(device,&pool,nullptr,&d.pool),"camera descriptor pool");
  VkDescriptorSetAllocateInfo sets{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO}; sets.descriptorPool=d.pool; sets.descriptorSetCount=1; sets.pSetLayouts=&d.descriptorLayout; check(vkAllocateDescriptorSets(device,&sets,&d.descriptors),"camera descriptors");
  VkDescriptorImageInfo infos[2]={{camera.sampler,camera.image.view,VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL},{d.sceneSampler,scene.view,VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL}};
  VkWriteDescriptorSet writes[2]{}; for(uint32_t i=0;i<2;i++) { writes[i].sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET; writes[i].dstSet=d.descriptors; writes[i].dstBinding=i; writes[i].descriptorCount=1; writes[i].descriptorType=VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER; writes[i].pImageInfo=&infos[i]; } vkUpdateDescriptorSets(device,2,writes,0,nullptr);
  VkPushConstantRange range{VK_SHADER_STAGE_FRAGMENT_BIT,0,32}; VkPipelineLayoutCreateInfo pl{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO}; pl.setLayoutCount=1; pl.pSetLayouts=&d.descriptorLayout; pl.pushConstantRangeCount=1; pl.pPushConstantRanges=&range; check(vkCreatePipelineLayout(device,&pl,nullptr,&d.layout),"camera pipeline layout");
  VkShaderModuleCreateInfo shader{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO}; shader.codeSize=sizeof(vertShader); shader.pCode=vertShader; check(vkCreateShaderModule(device,&shader,nullptr,&d.vert),"vertex shader"); shader.codeSize=sizeof(fragShader); shader.pCode=fragShader; check(vkCreateShaderModule(device,&shader,nullptr,&d.frag),"fragment shader");
  VkPipelineShaderStageCreateInfo stages[2]{}; for(auto& s:stages) { s.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO; s.pName="main"; } stages[0].stage=VK_SHADER_STAGE_VERTEX_BIT; stages[0].module=d.vert; stages[1].stage=VK_SHADER_STAGE_FRAGMENT_BIT; stages[1].module=d.frag;
  VkPipelineVertexInputStateCreateInfo vi{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO}; VkPipelineInputAssemblyStateCreateInfo ia{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO}; ia.topology=VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
  VkViewport viewport{0,0,static_cast<float>(width),static_cast<float>(height),0,1}; VkRect2D scissor{{0,0},{width,height}}; VkPipelineViewportStateCreateInfo vp{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO}; vp.viewportCount=1; vp.pViewports=&viewport; vp.scissorCount=1; vp.pScissors=&scissor;
  VkPipelineRasterizationStateCreateInfo raster{VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO}; raster.polygonMode=VK_POLYGON_MODE_FILL; raster.cullMode=VK_CULL_MODE_NONE; raster.lineWidth=1;
  VkPipelineMultisampleStateCreateInfo ms{VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO}; ms.rasterizationSamples=VK_SAMPLE_COUNT_1_BIT;
  VkPipelineColorBlendAttachmentState blend{}; blend.colorWriteMask=15; VkPipelineColorBlendStateCreateInfo bs{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO}; bs.attachmentCount=1; bs.pAttachments=&blend;
  VkGraphicsPipelineCreateInfo pi{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO}; pi.stageCount=2; pi.pStages=stages; pi.pVertexInputState=&vi; pi.pInputAssemblyState=&ia; pi.pViewportState=&vp; pi.pRasterizationState=&raster; pi.pMultisampleState=&ms; pi.pColorBlendState=&bs; pi.layout=d.layout; pi.renderPass=d.pass;
  check(vkCreateGraphicsPipelines(device,VK_NULL_HANDLE,1,&pi,nullptr,&d.pipeline),"camera graphics pipeline");
 }
 void barrier(VkImage image,VkImageLayout oldLayout,VkImageLayout newLayout,VkAccessFlags src,VkAccessFlags dst,uint32_t from=VK_QUEUE_FAMILY_IGNORED,uint32_t to=VK_QUEUE_FAMILY_IGNORED) {
  VkImageMemoryBarrier b{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER}; b.srcAccessMask=src; b.dstAccessMask=dst; b.oldLayout=oldLayout; b.newLayout=newLayout; b.srcQueueFamilyIndex=from; b.dstQueueFamilyIndex=to; b.image=image; b.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}; vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,0,0,nullptr,0,nullptr,1,&b);
 }
 void initializeDepth(FrameResources& resources,const uint8_t* bytes,size_t size,uint32_t sensorWidth,uint32_t sensorHeight,const float* calibration,uint64_t deadline) {
  if(sensorWidth==0 || sensorHeight==0 || sensorWidth>2048 || sensorHeight>2048 || size!=static_cast<size_t>(sensorWidth)*sensorHeight*4) throw std::runtime_error("Invalid depth dimensions.");
  auto& source=resources.source; auto& target=resources.projected; auto& d=resources.depthDraw; auto& depth=resources.depth;
  auto allocate=[&](Buffer& b,VkDeviceSize length,VkBufferUsageFlags usage,bool host) {
   VkBufferCreateInfo ci{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO}; ci.size=length; ci.usage=usage; ci.sharingMode=VK_SHARING_MODE_EXCLUSIVE; check(vkCreateBuffer(device,&ci,nullptr,&b.buffer),"depth buffer");
   VkMemoryRequirements req; vkGetBufferMemoryRequirements(device,b.buffer,&req); VkMemoryAllocateInfo alloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; alloc.allocationSize=req.size; alloc.memoryTypeIndex=memoryType(req.memoryTypeBits,host?(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT):0); check(vkAllocateMemory(device,&alloc,nullptr,&b.memory),"depth buffer allocation"); check(vkBindBufferMemory(device,b.buffer,b.memory,0),"depth buffer bind");
  };
  allocate(source,size,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,true);
  allocate(target,static_cast<VkDeviceSize>(width)*height*4,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT|VK_BUFFER_USAGE_TRANSFER_SRC_BIT,false);
  void* mapped; check(vkMapMemory(device,source.memory,0,size,0,&mapped),"depth staging map"); std::memcpy(mapped,bytes,size); vkUnmapMemory(device,source.memory);
  VkImageCreateInfo ci{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO}; ci.imageType=VK_IMAGE_TYPE_2D; ci.format=VK_FORMAT_D32_SFLOAT; ci.extent={width,height,1}; ci.mipLevels=1; ci.arrayLayers=1; ci.samples=VK_SAMPLE_COUNT_1_BIT; ci.tiling=VK_IMAGE_TILING_OPTIMAL; ci.usage=VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT; ci.sharingMode=VK_SHARING_MODE_EXCLUSIVE;
  VkFormatProperties formatProperties; vkGetPhysicalDeviceFormatProperties(physical,VK_FORMAT_D32_SFLOAT,&formatProperties);
  if(!(formatProperties.optimalTilingFeatures&VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT)) throw std::runtime_error("Vulkan D32 depth is unavailable.");
  check(vkCreateImage(device,&ci,nullptr,&depth.image),"initialized depth image"); VkMemoryRequirements req; vkGetImageMemoryRequirements(device,depth.image,&req); VkMemoryAllocateInfo alloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; alloc.allocationSize=req.size; alloc.memoryTypeIndex=memoryType(req.memoryTypeBits); check(vkAllocateMemory(device,&alloc,nullptr,&depth.memory),"depth image allocation"); check(vkBindImageMemory(device,depth.image,depth.memory,0),"depth image bind");
  VkDescriptorSetLayoutBinding bindings[2]{}; for(uint32_t i=0;i<2;i++) { bindings[i].binding=i; bindings[i].descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER; bindings[i].descriptorCount=1; bindings[i].stageFlags=VK_SHADER_STAGE_COMPUTE_BIT; }
  VkDescriptorSetLayoutCreateInfo layout{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO}; layout.bindingCount=2; layout.pBindings=bindings; check(vkCreateDescriptorSetLayout(device,&layout,nullptr,&d.descriptorLayout),"depth descriptor layout");
  VkDescriptorPoolSize poolSize{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,2}; VkDescriptorPoolCreateInfo pool{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO}; pool.maxSets=1; pool.poolSizeCount=1; pool.pPoolSizes=&poolSize; check(vkCreateDescriptorPool(device,&pool,nullptr,&d.pool),"depth descriptor pool");
  VkDescriptorSetAllocateInfo sets{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO}; sets.descriptorPool=d.pool; sets.descriptorSetCount=1; sets.pSetLayouts=&d.descriptorLayout; check(vkAllocateDescriptorSets(device,&sets,&d.descriptors),"depth descriptor set");
  VkDescriptorBufferInfo infos[2]={{source.buffer,0,size},{target.buffer,0,static_cast<VkDeviceSize>(width)*height*4}}; VkWriteDescriptorSet writes[2]{}; for(uint32_t i=0;i<2;i++) { writes[i].sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET; writes[i].dstSet=d.descriptors; writes[i].dstBinding=i; writes[i].descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER; writes[i].descriptorCount=1; writes[i].pBufferInfo=&infos[i]; } vkUpdateDescriptorSets(device,2,writes,0,nullptr);
  VkPushConstantRange range{VK_SHADER_STAGE_COMPUTE_BIT,0,64}; VkPipelineLayoutCreateInfo pl{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO}; pl.setLayoutCount=1; pl.pSetLayouts=&d.descriptorLayout; pl.pushConstantRangeCount=1; pl.pPushConstantRanges=&range; check(vkCreatePipelineLayout(device,&pl,nullptr,&d.layout),"depth pipeline layout");
  VkShaderModuleCreateInfo shader{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO}; shader.codeSize=sizeof(depthShader); shader.pCode=depthShader; check(vkCreateShaderModule(device,&shader,nullptr,&d.frag),"depth compute shader");
  VkComputePipelineCreateInfo pipeline{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO}; pipeline.stage.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO; pipeline.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT; pipeline.stage.module=d.frag; pipeline.stage.pName="main"; pipeline.layout=d.layout; check(vkCreateComputePipelines(device,VK_NULL_HANDLE,1,&pipeline,nullptr,&d.pipeline),"depth compute pipeline");
  check(vkResetCommandBuffer(command,0),"depth reset commands"); VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; begin.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT; check(vkBeginCommandBuffer(command,&begin),"depth begin");
  struct Push { float calibration[12]; uint32_t dimensions[4]; } push{};
  std::memcpy(push.calibration,calibration,48); push.dimensions[0]=width; push.dimensions[1]=height; push.dimensions[2]=sensorWidth; push.dimensions[3]=sensorHeight;
  vkCmdBindPipeline(command,VK_PIPELINE_BIND_POINT_COMPUTE,d.pipeline); vkCmdBindDescriptorSets(command,VK_PIPELINE_BIND_POINT_COMPUTE,d.layout,0,1,&d.descriptors,0,nullptr); vkCmdPushConstants(command,d.layout,VK_SHADER_STAGE_COMPUTE_BIT,0,64,&push); vkCmdDispatch(command,(width+7)/8,(height+7)/8,1);
  VkBufferMemoryBarrier bufferBarrier{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER}; bufferBarrier.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT; bufferBarrier.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT; bufferBarrier.srcQueueFamilyIndex=bufferBarrier.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED; bufferBarrier.buffer=target.buffer; bufferBarrier.offset=0; bufferBarrier.size=VK_WHOLE_SIZE; vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,1,&bufferBarrier,0,nullptr);
  VkImageMemoryBarrier imageBarrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER}; imageBarrier.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; imageBarrier.oldLayout=VK_IMAGE_LAYOUT_UNDEFINED; imageBarrier.newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; imageBarrier.srcQueueFamilyIndex=imageBarrier.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED; imageBarrier.image=depth.image; imageBarrier.subresourceRange={VK_IMAGE_ASPECT_DEPTH_BIT,0,1,0,1}; vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&imageBarrier);
  VkBufferImageCopy copy{}; copy.imageSubresource={VK_IMAGE_ASPECT_DEPTH_BIT,0,0,1}; copy.imageExtent={width,height,1}; vkCmdCopyBufferToImage(command,target.buffer,depth.image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,1,&copy);
  imageBarrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; imageBarrier.dstAccessMask=VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT|VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT; imageBarrier.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; imageBarrier.newLayout=VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL; vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,0,0,nullptr,0,nullptr,1,&imageBarrier);
  check(vkEndCommandBuffer(command),"depth end"); check(vkResetFences(device,1,&fence),"depth reset fence"); VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount=1; submit.pCommandBuffers=&command;
  // Keep staging resources alive on every submission failure path.
  requireDepthFresh(deadline);
  try { check(vkQueueSubmit(queue,1,&submit,fence),"depth submit"); check(vkWaitForFences(device,1,&fence,VK_TRUE,UINT64_MAX),"depth completion"); }
  catch(...) { vkDeviceWaitIdle(device); throw; }
 }
 void draw(AHardwareBuffer* buffer,const float* uv,const uint8_t* packet,size_t size,const uint8_t* depthBytes,size_t depthSize,uint32_t depthWidth,uint32_t depthHeight,const float* depthCalibration,uint64_t depthDeadline) {
  if(failed || pending || !swapchain) throw std::runtime_error("Camera presenter is unavailable or has a pending frame.");
  auto resources=std::make_unique<FrameResources>(device);
  auto& camera=resources->camera; auto& scene=resources->scene; auto& depth=resources->depth; auto& d=resources->draw;
  try {
   importCamera(camera,buffer); makeScene(scene);
   if(depthSize) initializeDepth(*resources,depthBytes,depthSize,depthWidth,depthHeight,depthCalibration,depthDeadline);
   requireDepthFresh(depthDeadline);
   runtime.require(runtime.render(runtime.renderer,packet,size,reinterpret_cast<uint64_t>(device),reinterpret_cast<uint64_t>(scene.image),reinterpret_cast<uint64_t>(depth.image),width,height));
   check(vkResetFences(device,1,&acquireFence),"reset acquisition fence");
   auto acquiredResult=vkAcquireNextImageKHR(device,swapchain,UINT64_MAX,acquired,acquireFence,&index);
   if(acquiredResult!=VK_SUBOPTIMAL_KHR) check(acquiredResult,"acquire camera drawable");
   acquisitionPending=true;
   check(vkWaitForFences(device,1,&acquireFence,VK_TRUE,UINT64_MAX),"drawable acquisition completion");
   acquisitionPending=false;
   if(presenting[index]) {
    check(vkWaitForFences(device,1,&presentFences[index],VK_TRUE,UINT64_MAX),"previous image presentation");
    presenting[index]=false;
   }
   pipeline(d,camera,scene);
   check(vkResetCommandBuffer(command,0),"reset commands"); VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; begin.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT; check(vkBeginCommandBuffer(command,&begin),"begin commands");
   barrier(camera.image.image,VK_IMAGE_LAYOUT_GENERAL,VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,0,VK_ACCESS_SHADER_READ_BIT,VK_QUEUE_FAMILY_FOREIGN_EXT,family);
   barrier(scene.image,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,VK_ACCESS_SHADER_READ_BIT);
   VkRenderPassBeginInfo pass{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO}; pass.renderPass=d.pass; pass.framebuffer=d.framebuffer; pass.renderArea={{0,0},{width,height}}; vkCmdBeginRenderPass(command,&pass,VK_SUBPASS_CONTENTS_INLINE); vkCmdBindPipeline(command,VK_PIPELINE_BIND_POINT_GRAPHICS,d.pipeline); vkCmdBindDescriptorSets(command,VK_PIPELINE_BIND_POINT_GRAPHICS,d.layout,0,1,&d.descriptors,0,nullptr);
   float calibration[8]={uv[2]-uv[0],uv[4]-uv[0],uv[0],0,uv[3]-uv[1],uv[5]-uv[1],uv[1],0}; vkCmdPushConstants(command,d.layout,VK_SHADER_STAGE_FRAGMENT_BIT,0,sizeof(calibration),calibration); vkCmdDraw(command,3,1,0,0); vkCmdEndRenderPass(command);
   barrier(camera.image.image,VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,VK_IMAGE_LAYOUT_GENERAL,VK_ACCESS_SHADER_READ_BIT,0,family,VK_QUEUE_FAMILY_FOREIGN_EXT);
   check(vkEndCommandBuffer(command),"end commands"); check(vkResetFences(device,1,&fence),"reset fence"); VkPipelineStageFlags wait=VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT; VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.waitSemaphoreCount=1; submit.pWaitSemaphores=&acquired; submit.pWaitDstStageMask=&wait; submit.commandBufferCount=1; submit.pCommandBuffers=&command; submit.signalSemaphoreCount=1; submit.pSignalSemaphores=&finished[index];
   check(vkQueueSubmit(queue,1,&submit,fence),"camera submit"); check(vkWaitForFences(device,1,&fence,VK_TRUE,UINT64_MAX),"camera GPU completion"); pending=true;
  } catch(const StaleDepth&) {
   if(!gpuRetired()) { failed=true; failedResources=std::move(resources); }
   throw;
  } catch(...) {
   failed=true;
   // An unexpected idle error gives no proof of GPU retirement. Keep every
   // borrowed image, staging buffer and camera reference until a later retry.
   if(!gpuRetired()) failedResources=std::move(resources);
   throw;
  }
 }
 void discard() {
  // A completed but revoked drawable must never reach presentation. Recreate
  // the swapchain to release its acquired image and the unconsumed semaphore.
  auto retained=window; if(retained) ANativeWindow_acquire(retained);
  auto w=width,h=height; attach(retained,w,h);
 }
 void publish() {
  if(!pending || failed) throw std::runtime_error("No completed camera frame.");
  check(vkResetFences(device,1,&presentFences[index]),"reset presentation fence");
  VkSwapchainPresentFenceInfoEXT completion{VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_FENCE_INFO_EXT}; completion.swapchainCount=1; completion.pFences=&presentFences[index];
  VkPresentInfoKHR present{VK_STRUCTURE_TYPE_PRESENT_INFO_KHR}; present.pNext=&completion; present.waitSemaphoreCount=1; present.pWaitSemaphores=&finished[index]; present.swapchainCount=1; present.pSwapchains=&swapchain; present.pImageIndices=&index;
  auto result=vkQueuePresentKHR(queue,&present); pending=false;
  // These results enqueue the waits, including the rejected presentation cases.
  presenting[index]=result==VK_SUCCESS || result==VK_SUBOPTIMAL_KHR || result==VK_ERROR_OUT_OF_DATE_KHR || result==VK_ERROR_SURFACE_LOST_KHR || result==VK_ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT;
  if(!presenting[index] && result!=VK_ERROR_OUT_OF_HOST_MEMORY && result!=VK_ERROR_OUT_OF_DEVICE_MEMORY && result!=VK_ERROR_DEVICE_LOST) presentationUnknown=true;
  if(result!=VK_SUCCESS && result!=VK_SUBOPTIMAL_KHR) { failed=true; check(result,"camera present"); }
 }

};
Presenter& get(jlong handle) { if(!handle) throw std::runtime_error("Camera presenter is closed."); return *reinterpret_cast<Presenter*>(handle); }
}
extern "C" JNIEXPORT jlong JNICALL Java_dev_zyren_xr_XrNative_create(JNIEnv* env,jobject,jlong token) { try { return reinterpret_cast<jlong>(new Presenter(static_cast<uint64_t>(token))); } catch(const std::exception& e) { fail(env,e); return 0; } }
extern "C" JNIEXPORT void JNICALL Java_dev_zyren_xr_XrNative_destroy(JNIEnv* env,jobject,jlong handle) {
 try { auto& p=get(handle); p.retire(); delete &p; }
 catch(const std::exception& e) { fail(env,e); }
}
extern "C" JNIEXPORT void JNICALL Java_dev_zyren_xr_XrNative_surface(JNIEnv* env,jobject,jlong handle,jobject surface,jint width,jint height) { try { get(handle).attach(surface?ANativeWindow_fromSurface(env,surface):nullptr,width,height); } catch(const std::exception& e) { fail(env,e); } }
extern "C" JNIEXPORT void JNICALL Java_dev_zyren_xr_XrNative_render(JNIEnv* env,jobject,jlong handle,jobject buffer,jfloatArray uv,jbyteArray packet,jbyteArray depth,jint depthWidth,jint depthHeight,jfloatArray depthCalibration,jlong depthDeadline) {
 try {
  if(!buffer || !uv || env->GetArrayLength(uv)!=6 || !packet || env->GetArrayLength(packet)==0 || env->GetArrayLength(packet)>128*1024*1024) throw std::runtime_error("Invalid camera frame input.");
  float coords[6]; env->GetFloatArrayRegion(uv,0,6,coords); std::vector<uint8_t> bytes(env->GetArrayLength(packet)); env->GetByteArrayRegion(packet,0,bytes.size(),reinterpret_cast<jbyte*>(bytes.data()));
  auto hardware=AHardwareBuffer_fromHardwareBuffer(env,buffer); if(!hardware) throw std::runtime_error("Invalid camera hardware buffer."); std::vector<uint8_t> depthData; float dc[12]={};
  if(depth) { auto length=env->GetArrayLength(depth); if(length<1 || length>2048*2048*4 || !depthCalibration || env->GetArrayLength(depthCalibration)!=12) throw std::runtime_error("Invalid depth input."); depthData.resize(length); env->GetByteArrayRegion(depth,0,length,reinterpret_cast<jbyte*>(depthData.data())); env->GetFloatArrayRegion(depthCalibration,0,12,dc); }
  get(handle).draw(hardware,coords,bytes.data(),bytes.size(),depthData.data(),depthData.size(),depthWidth,depthHeight,dc,static_cast<uint64_t>(depthDeadline));
 } catch(const std::exception& e) { fail(env,e); }
}
extern "C" JNIEXPORT void JNICALL Java_dev_zyren_xr_XrNative_publish(JNIEnv* env,jobject,jlong handle) { try { get(handle).publish(); } catch(const std::exception& e) { fail(env,e); } }
extern "C" JNIEXPORT jbyteArray JNICALL Java_dev_zyren_xr_XrNative_command(JNIEnv* env,jobject,jlong handle,jint kind,jbyteArray input,jint capacity) {
 try {
  if(kind<0 || kind>2 || !input || env->GetArrayLength(input)>64*1024*1024+2048 || capacity<1 || capacity>64*1024*1024+24) throw std::runtime_error("Invalid GPU command bounds.");
  auto& runtime=get(handle).runtime; std::vector<uint8_t> bytes(env->GetArrayLength(input)),out(capacity+4); env->GetByteArrayRegion(input,0,bytes.size(),reinterpret_cast<jbyte*>(bytes.data())); size_t written=0; auto status=runtime.commands[kind](runtime.renderer,bytes.data(),bytes.size(),out.data()+4,capacity,&written);
  if(status) { auto error=runtime.lastError(); out.resize(error.size()+4); std::memcpy(out.data()+4,error.data(),error.size()); } else { if(written>static_cast<size_t>(capacity)) throw std::runtime_error("GPU response exceeds capacity."); out.resize(written+4); }
  std::memcpy(out.data(),&status,4); auto result=env->NewByteArray(out.size()); env->SetByteArrayRegion(result,0,out.size(),reinterpret_cast<jbyte*>(out.data())); return result;
 } catch(const std::exception& e) { fail(env,e); return nullptr; }
}

extern "C" JNIEXPORT void JNICALL Java_dev_zyren_xr_XrNative_discard(JNIEnv* env,jobject,jlong handle) { try { get(handle).discard(); } catch(const std::exception& e) { fail(env,e); } }

extern "C" JNIEXPORT jlong JNICALL Java_dev_zyren_xr_XrNative_readback(JNIEnv* env,jobject,jlong handle) {
 try { auto& p=get(handle); uint64_t values[6]={}; p.runtime.require(p.runtime.context(p.runtime.renderer,values)); return static_cast<jlong>(values[5]); }
 catch(const std::exception& e) { fail(env,e); return 0; }
}
