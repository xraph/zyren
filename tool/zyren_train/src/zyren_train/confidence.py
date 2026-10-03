"""Wilson95 intervals keep failed/cancelled episodes in the denominator."""
import math


def wilson(successes,requested):
    if type(successes) is not int or type(requested) is not int or not 0<=successes<=requested or requested<1: raise ValueError('Invalid rate denominator')
    z=1.959963984540054; rate=successes/requested; denominator=1+z*z/requested
    center=(rate+z*z/(2*requested))/denominator
    radius=z*math.sqrt(rate*(1-rate)/requested+z*z/(4*requested*requested))/denominator
    return 0. if successes==0 else max(0.,center-radius),1. if successes==requested else min(1.,center+radius)
