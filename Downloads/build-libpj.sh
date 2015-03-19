#!/bin/sh

#  Automatic build script for pjsip 
#  for iPhoneOS and iPhoneSimulator
#
#  Copyright (C) 2011 Samuel <samuelv0304@gmail.com>
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License along
#  with this program; if not, write to the Free Software Foundation, Inc.,
#  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#
###########################################################################
# Install this script into a directory and define PJPROJECTDIR variable.  #
# You should not put this script directly into pjproject directory.       #
###########################################################################
#  Change values here													  #
#																		  #
PJPROJECTDIR=../
#export DEVPATH=/Developer/Platforms/iPhoneOS.platform/Developer          #
#export IPHONESDK=iPhoneOS4.2.sdk                                         #
#																		  #
###########################################################################
#																		  #
# Don't change anything under this line!								  #
#																		  #
###########################################################################

CURRENTPATH=`pwd`

set -e

cd ${PJPROJECTDIR}

############
# iPhone Simulator
#echo "Building pjproject for iPhoneSimulator i386"
#echo "Please stand by..."
#
#mkdir -p "${CURRENTPATH}/iPhoneSimulator.sdk"
#
#LOG="${CURRENTPATH}/iPhoneSimulator.sdk/build-pjproject-i386.log"
#
#make >> "${LOG}" 2>&1
#make install >> "${LOG}" 2>&1
#make clean >> "${LOG}" 2>&1
#make distclean >> "${LOG}" 2>&1
#############

#############
# iPhoneOS armv6
echo "Building pjproject for iPhoneOS armv6"
echo "Please stand by..."

export ARCH="-arch armv6"

mkdir -p "${CURRENTPATH}/iPhoneOS-armv6.sdk"

LOG="${CURRENTPATH}/iPhoneOS-armv6.sdk/build-pjproject-armv6.log"

./configure-iphone --prefix="${CURRENTPATH}/iPhoneOS-armv6.sdk" >> "${LOG}" 2>&1

make >> "${LOG}" 2>&1
make install >> "${LOG}" 2>&1
make clean >> "${LOG}" 2>&1
make distclean >> "${LOG}" 2>&1
#############

#############
# iPhoneOS armv7
echo "Building pjproject for iPhoneOS armv7"
echo "Please stand by..."

export ARCH="-arch armv7"

mkdir -p "${CURRENTPATH}/iPhoneOS-armv7.sdk"

LOG="${CURRENTPATH}/iPhoneOS-armv7.sdk/build-pjproject-armv7.log"

./configure-iphone --prefix="${CURRENTPATH}/iPhoneOS-armv7.sdk" >> "${LOG}" 2>&1

make >> "${LOG}" 2>&1
make install >> "${LOG}" 2>&1
make clean >> "${LOG}" 2>&1
make distclean >> "${LOG}" 2>&1
#############

#############
# universal lib
echo "Build library..."

mkdir -p "${CURRENTPATH}/lib"

for libpath in `ls -d ${CURRENTPATH}/iPhoneOS-armv6.sdk/lib/lib*.a`; do
	libname=`basename ${libpath}`
	#lipo -create ${CURRENTPATH}/iPhoneOS-armv6.sdk/lib/${libname} ${CURRENTPATH}/iPhoneOS-armv7.sdk/lib/${libname} ${CURRENTPATH}/iPhoneSimulator.sdk/lib/ ${libname} -output ${CURRENTPATH}/lib/${libname}
	lipo -create ${CURRENTPATH}/iPhoneOS-armv6.sdk/lib/${libname} ${CURRENTPATH}/iPhoneOS-armv7.sdk/lib/${libname} -output ${CURRENTPATH}/lib/${libname}
done

mkdir -p ${CURRENTPATH}/include/pjproject
cp -R ${CURRENTPATH}/iPhoneOS-armv6.sdk/include/* ${CURRENTPATH}/include/pjproject

echo "Building done."
echo "Cleaning up..."
rm -rf ${CURRENTPATH}/iPhone*.sdk
echo "Done."
