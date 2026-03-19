/*
 * Copyright (c) 2011-2014, The Linux Foundation. All rights reserved.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 and
 * only version 2 as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */

#ifndef __QCOM_IDLE_H
#define __QCOM_IDLE_H

#define MAX_CPUS_PER_CLUSTER	4
#define MAX_NUM_CLUSTER		4

extern unsigned long msm_pm_boot_vector[];
extern void msm_pm_boot_entry(void);

#endif /* __QCOM_IDLE_H */
