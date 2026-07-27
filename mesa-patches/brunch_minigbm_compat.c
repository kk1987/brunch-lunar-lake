/*
 * brunch-lnl: minigbm compatibility shims for Mesa libgbm.
 *
 * ChromeOS userspace links against private minigbm APIs that Mesa's
 * libgbm does not provide. Consumers on the volteer R149 image:
 *   - minigbm_create_default_device: crosvm, libvirglrenderer,
 *     virgl_render_server, libcros_camera (hard link-time dependency —
 *     crosvm dies with "symbol lookup error" without it, which breaks
 *     both Crostini (termina) and ARCVM/Play).
 *   - gbm_detect_device_info(_path): libvirglrenderer, runtime_probe.
 *   - gbm_bo_get_map_info: libvirglrenderer, crosvm.
 *   - gbm_bo_map2: libcros_camera.
 *
 * The device-detection helpers are ported from
 * chromiumos/platform/minigbm/minigbm_helpers.c (BSD), with the
 * amdgpu/radeon dGPU-vs-iGPU refinement dropped (this package is only
 * installed on Lunar Lake machines) and an "xe" driver entry added.
 */

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#include "gbm.h"
#include "gbmint.h"

/* From minigbm_helpers.h */
#define GBM_DEV_TYPE_FLAG_DISCRETE (1u << 0)
#define GBM_DEV_TYPE_FLAG_DISPLAY (1u << 1)
#define GBM_DEV_TYPE_FLAG_3D (1u << 2)
#define GBM_DEV_TYPE_FLAG_ARMSOC (1u << 3)
#define GBM_DEV_TYPE_FLAG_USB (1u << 4)
#define GBM_DEV_TYPE_FLAG_BLOCKED (1u << 5)
#define GBM_DEV_TYPE_FLAG_INTERNAL_LCD (1u << 6)

#define GBM_DETECT_FLAG_CONNECTED (1u << 0)

struct gbm_device_info {
   uint32_t dev_type_flags;
   int dri_node_num;
   unsigned int connectors;
   unsigned int connected;
};

/* From minigbm gbm.h */
enum gbm_bo_map_cache_mode {
   GBM_BO_MAP_CACHE_CACHED = 1,
   GBM_BO_MAP_CACHE_WC = 3,
};

int gbm_detect_device_info(unsigned int detect_flags, int fd,
                           struct gbm_device_info *info);
int gbm_detect_device_info_path(unsigned int detect_flags,
                                const char *dev_node,
                                struct gbm_device_info *info);
struct gbm_device *minigbm_create_default_device(int *out_fd);
enum gbm_bo_map_cache_mode gbm_bo_get_map_info(struct gbm_bo *bo);
void *gbm_bo_map2(struct gbm_bo *bo, uint32_t x, uint32_t y, uint32_t width,
                  uint32_t height, uint32_t transfer_flags, uint32_t *stride,
                  void **map_data, int plane);

static int dri_node_num(const char *dri_node)
{
   long num;
   ssize_t l = strlen(dri_node);

   while (l > 0 && isdigit(dri_node[l - 1]))
      l--;
   num = strtol(dri_node + l, NULL, 10);
   if (num >= 128)
      num -= 128;
   return num;
}

static int fd_node_num(int fd)
{
   char fd_path[64];
   char dri_node[256];
   ssize_t dri_node_size;

   snprintf(fd_path, sizeof(fd_path), "/proc/self/fd/%d", fd);
   dri_node_size = readlink(fd_path, dri_node, sizeof(dri_node) - 1);
   if (dri_node_size < 0)
      return -errno;
   dri_node[dri_node_size] = '\0';
   return dri_node_num(dri_node);
}

static int detect_device_info(unsigned int detect_flags, int fd,
                              struct gbm_device_info *info)
{
   drmVersionPtr version;
   drmModeResPtr resources;

   info->dev_type_flags = 0;

   version = drmGetVersion(fd);
   if (!version)
      return -EINVAL;

   resources = drmModeGetResources(fd);
   if (resources) {
      info->connectors = (unsigned int)(resources->count_connectors);
      if (resources->count_connectors)
         info->dev_type_flags |= GBM_DEV_TYPE_FLAG_DISPLAY;
      if (detect_flags & GBM_DETECT_FLAG_CONNECTED) {
         int c;
         for (c = 0; c < resources->count_connectors; c++) {
            drmModeConnectorPtr conn =
               drmModeGetConnector(fd, resources->connectors[c]);
            if (!conn)
               continue;
            if (conn->connection == DRM_MODE_CONNECTED)
               info->connected++;
            if (conn->connector_type == DRM_MODE_CONNECTOR_eDP ||
                conn->connector_type == DRM_MODE_CONNECTOR_LVDS ||
                conn->connector_type == DRM_MODE_CONNECTOR_DSI ||
                conn->connector_type == DRM_MODE_CONNECTOR_DPI)
               info->dev_type_flags |= GBM_DEV_TYPE_FLAG_INTERNAL_LCD;
            drmModeFreeConnector(conn);
         }
      }
      drmModeFreeResources(resources);
   }

#define DRV_IS(n) (strncmp(n, version->name, version->name_len) == 0)
   if (DRV_IS("i915") || DRV_IS("xe") || DRV_IS("amdgpu")) {
      info->dev_type_flags |= GBM_DEV_TYPE_FLAG_DISPLAY | GBM_DEV_TYPE_FLAG_3D;
   } else if (DRV_IS("radeon") || DRV_IS("nvidia") || DRV_IS("nouveau")) {
      info->dev_type_flags |= GBM_DEV_TYPE_FLAG_DISPLAY |
                              GBM_DEV_TYPE_FLAG_3D | GBM_DEV_TYPE_FLAG_DISCRETE;
   } else if (DRV_IS("msm") || DRV_IS("vc4")) {
      info->dev_type_flags |= GBM_DEV_TYPE_FLAG_DISPLAY |
                              GBM_DEV_TYPE_FLAG_3D | GBM_DEV_TYPE_FLAG_ARMSOC;
   } else if (DRV_IS("armada") || DRV_IS("exynos") || DRV_IS("mediatek") ||
              DRV_IS("rockchip") || DRV_IS("omapdrm")) {
      info->dev_type_flags |= GBM_DEV_TYPE_FLAG_DISPLAY | GBM_DEV_TYPE_FLAG_ARMSOC;
   } else if (DRV_IS("etnaviv") || DRV_IS("lima") || DRV_IS("panfrost") ||
              DRV_IS("pvr") || DRV_IS("v3d")) {
      info->dev_type_flags |= GBM_DEV_TYPE_FLAG_3D | GBM_DEV_TYPE_FLAG_ARMSOC;
   } else if (DRV_IS("vgem")) {
      info->dev_type_flags |= GBM_DEV_TYPE_FLAG_BLOCKED;
   } else if (DRV_IS("evdi") || DRV_IS("udl")) {
      info->dev_type_flags |= GBM_DEV_TYPE_FLAG_DISPLAY |
                              GBM_DEV_TYPE_FLAG_USB | GBM_DEV_TYPE_FLAG_BLOCKED;
   }
#undef DRV_IS

   drmFreeVersion(version);
   return 0;
}

GBM_EXPORT int gbm_detect_device_info(unsigned int detect_flags, int fd,
                                      struct gbm_device_info *info)
{
   if (!info)
      return -EINVAL;
   memset(info, 0, sizeof(*info));
   info->dri_node_num = fd_node_num(fd);
   return detect_device_info(detect_flags, fd, info);
}

GBM_EXPORT int gbm_detect_device_info_path(unsigned int detect_flags,
                                           const char *dev_node,
                                           struct gbm_device_info *info)
{
   char rendernode_name[64];
   int fd;
   int ret;

   if (!info)
      return -EINVAL;
   memset(info, 0, sizeof(*info));
   info->dri_node_num = dri_node_num(dev_node);

   snprintf(rendernode_name, sizeof(rendernode_name), "/dev/dri/renderD%d",
            info->dri_node_num + 128);
   fd = open(rendernode_name, O_RDWR | O_CLOEXEC | O_NOCTTY | O_NONBLOCK);
   if (fd < 0)
      return -errno;
   ret = detect_device_info(detect_flags, fd, info);
   close(fd);
   return ret;
}

static int gbm_get_default_device_fd(void)
{
   DIR *dir;
   int ret, fd, dfd = -1;
   char *rendernode_name;
   struct dirent *dir_ent;
   struct gbm_device_info info;

   dir = opendir("/dev/dri");
   if (!dir)
      return -errno;

   fd = -1;
   while ((dir_ent = readdir(dir))) {
      if (dir_ent->d_type != DT_CHR)
         continue;
      if (strncmp(dir_ent->d_name, "renderD", 7))
         continue;

      ret = asprintf(&rendernode_name, "/dev/dri/%s", dir_ent->d_name);
      if (ret < 0)
         continue;

      fd = open(rendernode_name, O_RDWR | O_CLOEXEC | O_NOCTTY | O_NONBLOCK);
      free(rendernode_name);
      if (fd < 0)
         continue;

      memset(&info, 0, sizeof(info));
      if (detect_device_info(0, fd, &info) < 0) {
         close(fd);
         fd = -1;
         continue;
      }
      if (info.dev_type_flags & GBM_DEV_TYPE_FLAG_BLOCKED) {
         close(fd);
         fd = -1;
         continue;
      }
      dfd = fd;
      break;
   }
   closedir(dir);

   return dfd;
}

static struct gbm_device *try_drm_devices(drmDevicePtr *devs, int dev_count,
                                          int type, int *out_fd)
{
   int i;

   for (i = 0; i < dev_count; i++) {
      drmDevicePtr dev = devs[i];
      int fd;

      if (!(dev->available_nodes & (1 << type)))
         continue;

      fd = open(dev->nodes[type], O_RDWR | O_CLOEXEC);
      if (fd >= 0) {
         struct gbm_device *gbm = gbm_create_device(fd);
         if (gbm) {
            /* Drop DRM master taken by accident on a primary node so
             * programs that actually need it (e.g. Chrome) aren't
             * blocked. */
            if (type == DRM_NODE_PRIMARY && drmIsMaster(fd))
               drmDropMaster(fd);
            *out_fd = fd;
            return gbm;
         }
         close(fd);
      }
   }

   return NULL;
}

GBM_EXPORT struct gbm_device *minigbm_create_default_device(int *out_fd)
{
   struct gbm_device *gbm;
   drmDevicePtr devs[64];
   int dev_count;
   int fd;

   fd = gbm_get_default_device_fd();
   if (fd >= 0) {
      gbm = gbm_create_device(fd);
      if (gbm) {
         *out_fd = fd;
         return gbm;
      }
      close(fd);
   }

   dev_count = drmGetDevices2(0, devs, sizeof(devs) / sizeof(devs[0]));

   gbm = try_drm_devices(devs, dev_count, DRM_NODE_RENDER, out_fd);
   if (!gbm)
      gbm = try_drm_devices(devs, dev_count, DRM_NODE_PRIMARY, out_fd);

   drmFreeDevices(devs, dev_count);

   return gbm;
}

/*
 * Intel BOs are write-combine mapped in practice; minigbm reports CACHED
 * only for explicitly cached buffers. WC is the safe answer for iris/xe.
 */
GBM_EXPORT enum gbm_bo_map_cache_mode gbm_bo_get_map_info(struct gbm_bo *bo)
{
   (void)bo;
   return GBM_BO_MAP_CACHE_WC;
}

/*
 * minigbm's per-plane map. Mesa can only map the whole BO (plane 0);
 * that covers every observed caller. Refuse non-zero planes rather than
 * returning a wrong mapping.
 */
GBM_EXPORT void *gbm_bo_map2(struct gbm_bo *bo, uint32_t x, uint32_t y,
                             uint32_t width, uint32_t height,
                             uint32_t transfer_flags, uint32_t *stride,
                             void **map_data, int plane)
{
   if (plane != 0)
      return MAP_FAILED;
   return gbm_bo_map(bo, x, y, width, height, transfer_flags, stride,
                     map_data);
}
